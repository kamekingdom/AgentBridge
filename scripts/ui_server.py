#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import shlex
import subprocess
import tempfile
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


PROJECT_ROOT = Path(__file__).resolve().parent.parent
UI_ROOT = PROJECT_ROOT / "ui"
PROJECTS_ROOT = PROJECT_ROOT / "projects"
CURRENT_PROJECT_FILE = PROJECT_ROOT / ".current_project"
HOST = "127.0.0.1"
PORT = 8765


def shutil_which(command: str) -> str | None:
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory) / command
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def resolve_codex_path() -> str | None:
    env_override = os.environ.get("CODEX_BIN", "").strip()
    if env_override:
        candidate = Path(env_override).expanduser()
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)

    from_path = shutil_which("codex")
    if from_path:
        return from_path

    vscode_extensions = Path.home() / ".vscode" / "extensions"
    if vscode_extensions.exists():
        matches = sorted(vscode_extensions.glob("openai.chatgpt-*/bin/*/codex"), reverse=True)
        for match in matches:
            if match.exists() and os.access(match, os.X_OK):
                return str(match)

    fallback_candidates = [
        Path.home() / ".codex" / "bin" / "codex",
        Path("/opt/homebrew/bin/codex"),
        Path("/usr/local/bin/codex"),
    ]
    for candidate in fallback_candidates:
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)

    return None


CODEX_BIN = resolve_codex_path()


def read_config(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists():
      return data

    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key in {"host", "port", "user", "remote_root", "local_root"}:
            data[key] = value
    return data


def write_config(path: Path, config: dict[str, str]) -> None:
    content = "\n".join(
        [
            f'host: "{config.get("host", "your-remote-host")}"',
            f'port: {config.get("port", "22")}',
            f'user: "{config.get("user", "your-user")}"',
            f'remote_root: "{config.get("remote_root", "/home/your-user/project")}"',
            f'local_root: "{config.get("local_root", "remote")}"',
            "",
        ]
    )
    path.write_text(content, encoding="utf-8")


def sanitize_project_name(value: str) -> str:
    cleaned = "".join(ch if ch.isalnum() or ch in "._-" else "-" for ch in value.strip())
    return cleaned or "default"


def ensure_project(name: str) -> Path:
    project_name = sanitize_project_name(name)
    workspace = PROJECTS_ROOT / project_name
    (workspace / "remote").mkdir(parents=True, exist_ok=True)
    (workspace / "logs").mkdir(parents=True, exist_ok=True)
    (workspace / "remote" / ".gitkeep").touch()
    (workspace / "logs" / ".gitkeep").touch()
    config_path = workspace / "config.yml"
    if not config_path.exists():
        write_config(
            config_path,
            {
                "host": "your-remote-host",
                "port": "22",
                "user": "your-user",
                "remote_root": "/home/your-user/project",
                "local_root": "remote",
            },
        )
    return workspace


def list_projects() -> list[dict[str, object]]:
    PROJECTS_ROOT.mkdir(exist_ok=True)
    current = current_project()
    items: list[dict[str, object]] = []
    for child in sorted(PROJECTS_ROOT.iterdir()):
        if not child.is_dir():
            continue
        config = read_config(child / "config.yml")
        items.append(
            {
                "name": child.name,
                "workspace": f"projects/{child.name}",
                "config": config,
                "current": child.name == current,
            }
        )
    return items


def current_project() -> str:
    if CURRENT_PROJECT_FILE.exists():
        return CURRENT_PROJECT_FILE.read_text(encoding="utf-8").strip() or "default"
    return "default"


def set_current_project(name: str) -> None:
    CURRENT_PROJECT_FILE.write_text(f"{sanitize_project_name(name)}\n", encoding="utf-8")


def format_message_for_prompt(item: dict[str, object]) -> str:
    role = str(item.get("role", "user")).upper()
    content = str(item.get("content", "")).strip()
    attachments = item.get("attachments", [])

    lines = [f"{role}: {content or '[no text]'}"]

    if isinstance(attachments, list) and attachments:
        for attachment in attachments[:8]:
            name = str(attachment.get("name", "unknown"))
            kind = str(attachment.get("kind", "binary"))
            file_type = str(attachment.get("type", "application/octet-stream"))
            size = attachment.get("size", 0)
            lines.append(f"ATTACHMENT: {name} ({kind}, {file_type}, {size} bytes)")

            if kind == "text":
                attachment_content = str(attachment.get("content", "")).strip()
                if attachment_content:
                    lines.append(f"<file name=\"{name}\">")
                    lines.append(attachment_content)
                    lines.append("</file>")

    return "\n".join(lines)


def build_codex_prompt(project: str, config: dict[str, str], messages: list[dict[str, str]], user_input: str) -> str:
    history = []
    for item in messages[-8:]:
        history.append(format_message_for_prompt(item))

    return f"""
You are assisting with Remote Codex Bridge.

Active project: {project}
Workspace: projects/{project}
Remote workspace mirror: projects/{project}/{config.get("local_root", "remote")}
Remote host: {config.get("user", "your-user")}@{config.get("host", "your-remote-host")}:{config.get("port", "22")}
Remote root: {config.get("remote_root", "/home/your-user/project")}

Respond in Japanese. Be concise but useful.
Focus on actionable help for this project. When useful, include exact commands for:
- ./scripts/ab.sh --project {project} status
- ./scripts/ab.sh --project {project} tree .
- ./scripts/ab.sh --project {project} pull <path>
- ./scripts/ab.sh --project {project} push <path>
- ./scripts/ab.sh --project {project} exec "<command>"
- ./scripts/ab.sh --project {project} diff

Avoid pretending you executed anything unless it is explicitly stated.
If the request is ambiguous, suggest the most likely next command.

Recent conversation:
{os.linesep.join(history) if history else "No prior conversation."}

Latest user message:
{user_input}
""".strip()


def run_codex(project: str, config: dict[str, str], messages: list[dict[str, str]], user_input: str) -> dict[str, object]:
    if not CODEX_BIN:
        return {
            "ok": False,
            "message": "Codex CLI が見つかりません。",
            "details": "ui_server.py から実行できる codex バイナリを検出できませんでした。CODEX_BIN を設定するか、codex が PATH に入る状態で起動してください。",
        }

    prompt = build_codex_prompt(project, config, messages, user_input)
    output_file = tempfile.NamedTemporaryFile(prefix="codex-ui-", suffix=".txt", delete=False)
    output_file.close()

    cmd = [
        CODEX_BIN,
        "-s",
        "workspace-write",
        "-a",
        "never",
        "exec",
        "--skip-git-repo-check",
        "-C",
        str(PROJECT_ROOT),
        "-o",
        output_file.name,
        prompt,
    ]

    try:
        completed = subprocess.run(
            cmd,
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            timeout=180,
        )
    except FileNotFoundError as exc:
        return {
            "ok": False,
            "message": "Codex CLI の起動に失敗しました。",
            "details": f"{exc.filename} が見つかりません。CODEX_BIN または PATH を確認してください。",
            "command": " ".join(shlex.quote(part) for part in cmd),
        }

    stdout = completed.stdout.strip()
    stderr = completed.stderr.strip()

    if completed.returncode != 0:
        return {
            "ok": False,
            "message": "Codex CLI の呼び出しに失敗しました。",
            "details": stderr or stdout or "Unknown error",
            "command": " ".join(shlex.quote(part) for part in cmd),
        }

    reply = Path(output_file.name).read_text(encoding="utf-8").strip()
    if not reply:
        reply = stdout or "Codex から空の応答が返りました。"

    return {
        "ok": True,
        "message": reply,
        "raw_stdout": stdout,
    }


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, payload: dict[str, object], status: int = 200) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _send_file(self, path: Path) -> None:
        if not path.exists() or not path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND, "Not found")
            return

        content_type = "text/plain; charset=utf-8"
        if path.suffix == ".html":
            content_type = "text/html; charset=utf-8"
        elif path.suffix == ".css":
            content_type = "text/css; charset=utf-8"
        elif path.suffix == ".js":
            content_type = "application/javascript; charset=utf-8"

        data = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/projects":
            self._send_json(
                {
                    "projects": list_projects(),
                    "current": current_project(),
                    "codex_available": bool(CODEX_BIN),
                    "codex_path": CODEX_BIN,
                }
            )
            return

        if parsed.path in {"/", "/index.html"}:
            self._send_file(UI_ROOT / "index.html")
            return

        safe_path = (UI_ROOT / parsed.path.lstrip("/")).resolve()
        if UI_ROOT not in safe_path.parents and safe_path != UI_ROOT:
            self.send_error(HTTPStatus.FORBIDDEN, "Forbidden")
            return
        self._send_file(safe_path)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8") if length else "{}"
        payload = json.loads(body or "{}")

        if parsed.path == "/api/projects":
            name = sanitize_project_name(str(payload.get("name", "default")))
            config = payload.get("config", {})
            workspace = ensure_project(name)
            write_config(workspace / "config.yml", {**read_config(workspace / "config.yml"), **config})
            set_current_project(name)
            self._send_json(
                {
                    "ok": True,
                    "project": {
                        "name": name,
                        "workspace": f"projects/{name}",
                        "config": read_config(workspace / "config.yml"),
                    },
                }
            )
            return

        if parsed.path == "/api/chat":
            name = sanitize_project_name(str(payload.get("project", "default")))
            workspace = ensure_project(name)
            config = read_config(workspace / "config.yml")
            messages = payload.get("messages", [])
            user_input = str(payload.get("message", "")).strip()
            set_current_project(name)
            result = run_codex(name, config, messages, user_input)
            status = 200 if result.get("ok") else 500
            self._send_json(result, status=status)
            return

        self.send_error(HTTPStatus.NOT_FOUND, "Not found")

    def log_message(self, format: str, *args: object) -> None:
        return

if __name__ == "__main__":
    ensure_project(current_project())
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Remote Codex Bridge UI server running at http://{HOST}:{PORT}")
    print(f"Codex binary: {CODEX_BIN or 'not found'}")
    server.serve_forever()
