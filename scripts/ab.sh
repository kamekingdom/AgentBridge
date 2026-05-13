#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECTS_DIR="$PROJECT_ROOT/projects"
CURRENT_PROJECT_FILE="$PROJECT_ROOT/.current_project"
CONFIG_TEMPLATE_FILE="$PROJECT_ROOT/config.example.yml"

ACTIVE_PROJECT=""
WORKSPACE_ROOT=""
CONFIG_FILE=""
LOG_FILE=""

HOST=""
PORT=""
USER_NAME=""
REMOTE_ROOT=""
LOCAL_ROOT=""

ssh_opts=()

print_help() {
  cat <<'EOF'
Remote Codex Bridge

Usage:
  ./scripts/ab.sh help
  ./scripts/ab.sh gui
  ./scripts/ab.sh gui-serve
  ./scripts/ab.sh project init <name>
  ./scripts/ab.sh project list
  ./scripts/ab.sh project use <name>
  ./scripts/ab.sh project current
  ./scripts/ab.sh [--project <name>] status
  ./scripts/ab.sh [--project <name>] ls <path>
  ./scripts/ab.sh [--project <name>] tree <path>
  ./scripts/ab.sh [--project <name>] cat <path>
  ./scripts/ab.sh [--project <name>] pull <path>
  ./scripts/ab.sh [--project <name>] push <path>
  ./scripts/ab.sh [--project <name>] sync
  ./scripts/ab.sh [--project <name>] exec "<command>"
  ./scripts/ab.sh [--project <name>] diff
  ./scripts/ab.sh [--project <name>] log

Projects:
  Workspaces live under projects/<name>/.
  Each workspace owns its own config.yml, remote/, and logs/.

Examples:
  ./scripts/ab.sh project init client-a
  ./scripts/ab.sh project use client-a
  ./scripts/ab.sh project current
  ./scripts/ab.sh status
  ./scripts/ab.sh --project client-a tree .
  ./scripts/ab.sh --project client-a pull src/main.py
  ./scripts/ab.sh --project client-a exec "pytest"
EOF
}

error() {
  echo "Error: $*" >&2
}

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

require_local_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    error "ローカルで '$name' が見つかりません。インストールしてから再実行してください。"
    exit 1
  fi
}

shell_quote() {
  local value="${1:-}"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

validate_project_name() {
  local name="$1"

  if [[ -z "$name" ]]; then
    error "project 名が空です"
    exit 1
  fi

  case "$name" in
    *"/"*|*".."*|*" "*)
      error "project 名には '/', '..', 空白を含められません: $name"
      exit 1
      ;;
  esac

  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    error "project 名は英数字、'.', '_', '-' のみ使えます: $name"
    exit 1
  fi
}

current_project_name() {
  local fallback="${1:-default}"

  if [[ -n "$ACTIVE_PROJECT" ]]; then
    printf '%s' "$ACTIVE_PROJECT"
    return
  fi

  if [[ -f "$CURRENT_PROJECT_FILE" ]]; then
    local saved
    saved="$(trim "$(cat "$CURRENT_PROJECT_FILE")")"
    if [[ -n "$saved" ]]; then
      printf '%s' "$saved"
      return
    fi
  fi

  printf '%s' "$fallback"
}

set_workspace_context() {
  ACTIVE_PROJECT="$(current_project_name)"
  validate_project_name "$ACTIVE_PROJECT"
  WORKSPACE_ROOT="$PROJECTS_DIR/$ACTIVE_PROJECT"
  CONFIG_FILE="$WORKSPACE_ROOT/config.yml"
  LOG_FILE="$WORKSPACE_ROOT/logs/operations.log"
}

write_current_project() {
  mkdir -p "$PROJECTS_DIR"
  printf '%s\n' "$1" >"$CURRENT_PROJECT_FILE"
}

create_workspace_skeleton() {
  local name="$1"
  local workspace_root="$PROJECTS_DIR/$name"

  mkdir -p "$workspace_root/remote" "$workspace_root/logs"
  touch "$workspace_root/remote/.gitkeep" "$workspace_root/logs/.gitkeep"

  if [[ ! -f "$workspace_root/config.yml" ]]; then
    if [[ -f "$CONFIG_TEMPLATE_FILE" ]]; then
      cp "$CONFIG_TEMPLATE_FILE" "$workspace_root/config.yml"
    else
      cat >"$workspace_root/config.yml" <<'EOF'
host: "your-remote-host"
port: 22
user: "your-user"
remote_root: "/home/your-user/project"
local_root: "remote"
EOF
    fi
  fi
}

load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    error "config.yml が見つかりません: $CONFIG_FILE"
    error "先に ./scripts/ab.sh project init <name> を実行するか、workspace に config.yml を配置してください。"
    exit 1
  fi

  HOST=""
  PORT=""
  USER_NAME=""
  REMOTE_ROOT=""
  LOCAL_ROOT=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ -z "${line//[[:space:]]/}" ]] && continue

    local key="${line%%:*}"
    local value="${line#*:}"
    key="$(trim "$key")"
    value="$(trim "$value")"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"

    case "$key" in
      host) HOST="$value" ;;
      port) PORT="$value" ;;
      user) USER_NAME="$value" ;;
      remote_root) REMOTE_ROOT="$value" ;;
      local_root) LOCAL_ROOT="$value" ;;
    esac
  done <"$CONFIG_FILE"

  if [[ -z "$HOST" || -z "$PORT" || -z "$USER_NAME" || -z "$REMOTE_ROOT" || -z "$LOCAL_ROOT" ]]; then
    error "config.yml の必須キーが不足しています: $CONFIG_FILE"
    exit 1
  fi
}

ssh_target() {
  printf '%s@%s' "$USER_NAME" "$HOST"
}

build_ssh_opts() {
  ssh_opts=(-p "$PORT" -o BatchMode=yes -o ConnectTimeout=10)
}

run_ssh() {
  local remote_script="$1"

  if ! ssh "${ssh_opts[@]}" "$(ssh_target)" "sh -lc $(shell_quote "$remote_script")"; then
    error "SSH 実行に失敗しました。project 設定、接続先、鍵、remote_root を確認してください。"
    exit 1
  fi
}

normalize_rel_path() {
  local path="${1:-}"

  while [[ "$path" == ./* ]]; do
    path="${path#./}"
  done

  if [[ -z "$path" ]]; then
    path="."
  fi

  if [[ "$path" != "." ]]; then
    while [[ "$path" == */ ]]; do
      path="${path%/}"
    done
  fi

  printf '%s' "$path"
}

reject_invalid_path() {
  local path
  path="$(normalize_rel_path "${1:-}")"

  if [[ -z "$path" ]]; then
    error "path が空です"
    exit 1
  fi

  if [[ "$path" == /* ]]; then
    error "絶対パスは指定できません: $path"
    exit 1
  fi

  if [[ "$path" == *".."* ]]; then
    error "'..' を含む path は指定できません: $path"
    exit 1
  fi

  if [[ "$path" == *$'\n'* ]]; then
    error "改行を含む path は指定できません"
    exit 1
  fi
}

reject_protected_path() {
  local path
  path="$(normalize_rel_path "${1:-}")"

  case "$path" in
    .env|.env/*|*/.env|*/.env/*|.env.local|.env.local/*|*/.env.local|*/.env.local/*|secrets|secrets/*|*/secrets|*/secrets/*|~/.ssh|~/.ssh/*|.ssh|.ssh/*|*/.ssh|*/.ssh/*)
      error "保護対象のパスにはアクセスできません: $path"
      exit 1
      ;;
  esac
}

reject_dangerous_command() {
  local command="$1"

  case "$command" in
    *"sudo"*|*" su "*|su|su\ *|*"shutdown"*|*"reboot"*|*"systemctl"*|*"rm -rf /"*|*":(){ :|:& };:"*)
      error "危険なコマンドが含まれているため exec を拒否しました"
      exit 1
      ;;
  esac
}

ensure_workspace_dirs() {
  mkdir -p "$WORKSPACE_ROOT/logs" "$WORKSPACE_ROOT/$LOCAL_ROOT"
}

log_operation() {
  mkdir -p "$(dirname "$LOG_FILE")"
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$ACTIVE_PROJECT" "$*" >>"$LOG_FILE"
}

rsync_excludes_pull=(
  --exclude=.git
  --exclude=node_modules
  --exclude=.venv
  --exclude=venv
  --exclude=__pycache__
  --exclude=.pytest_cache
  --exclude=.mypy_cache
  --exclude=dist
  --exclude=build
  --exclude=outputs
  --exclude=checkpoints
  --exclude=wandb
  --exclude=.env
  --exclude=.env.local
  --exclude=secrets
)

rsync_excludes_sync=(
  --exclude=.git
  --exclude=node_modules
  --exclude=.venv
  --exclude=venv
  --exclude=__pycache__
  --exclude=.pytest_cache
  --exclude=.mypy_cache
  --exclude=dist
  --exclude=build
  --exclude=data
  --exclude=datasets
  --exclude=outputs
  --exclude=checkpoints
  --exclude=wandb
  --exclude=.env
  --exclude=.env.local
  --exclude=secrets
)

do_project_init() {
  local name="$1"
  validate_project_name "$name"
  create_workspace_skeleton "$name"
  write_current_project "$name"
  echo "Initialized workspace: projects/$name"
  echo "Config: projects/$name/config.yml"
  echo "Remote mirror: projects/$name/remote/"
  echo "Logs: projects/$name/logs/"
}

do_project_list() {
  mkdir -p "$PROJECTS_DIR"
  local current
  current="$(current_project_name "")"
  local found=0

  for dir in "$PROJECTS_DIR"/*; do
    [[ -d "$dir" ]] || continue
    local name
    name="$(basename "$dir")"
    found=1
    if [[ -n "$current" && "$name" == "$current" ]]; then
      echo "* $name"
    else
      echo "  $name"
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    echo "No projects yet. Run: ./scripts/ab.sh project init <name>"
  fi
}

do_project_use() {
  local name="$1"
  validate_project_name "$name"
  if [[ ! -d "$PROJECTS_DIR/$name" ]]; then
    error "workspace が存在しません: projects/$name"
    exit 1
  fi
  if [[ ! -f "$PROJECTS_DIR/$name/config.yml" ]]; then
    error "config.yml が存在しません: projects/$name/config.yml"
    exit 1
  fi
  write_current_project "$name"
  echo "Current project: $name"
}

do_project_current() {
  set_workspace_context
  echo "Current project: $ACTIVE_PROJECT"
  echo "Workspace: $WORKSPACE_ROOT"
  if [[ -f "$CONFIG_FILE" ]]; then
    echo "Config: $CONFIG_FILE"
  else
    echo "Config: missing"
  fi
}

do_status() {
  require_local_command ssh
  ensure_workspace_dirs
  log_operation "status"
  echo "== Project =="
  echo "$ACTIVE_PROJECT"
  echo "== Workspace =="
  echo "$WORKSPACE_ROOT"
  echo "== SSH check =="
  if ! ssh "${ssh_opts[@]}" "$(ssh_target)" "exit 0"; then
    error "SSH 接続に失敗しました。host, port, user, SSH 鍵を確認してください。"
    exit 1
  fi

  echo "== Remote status =="
  run_ssh "cd $(shell_quote "$REMOTE_ROOT") || exit 1
printf 'pwd: '
pwd
if command -v git >/dev/null 2>&1; then
  echo '--- git status --short ---'
  git status --short 2>/dev/null || true
fi
echo '--- ls -la ---'
ls -la"
}

do_ls() {
  local path
  path="$(normalize_rel_path "$1")"
  reject_invalid_path "$path"
  require_local_command ssh
  ensure_workspace_dirs
  log_operation "ls $path"
  run_ssh "cd $(shell_quote "$REMOTE_ROOT") && ls -la -- $(shell_quote "$path")"
}

do_tree() {
  local path
  path="$(normalize_rel_path "$1")"
  reject_invalid_path "$path"
  require_local_command ssh
  ensure_workspace_dirs
  log_operation "tree $path"
  run_ssh "cd $(shell_quote "$REMOTE_ROOT") &&
if command -v tree >/dev/null 2>&1; then
  tree $(shell_quote "$path")
else
  find $(shell_quote "$path") -mindepth 0 -maxdepth 3 | sort
fi"
}

do_cat() {
  local path
  path="$(normalize_rel_path "$1")"
  reject_invalid_path "$path"
  reject_protected_path "$path"
  require_local_command ssh
  ensure_workspace_dirs
  log_operation "cat $path"
  run_ssh "cd $(shell_quote "$REMOTE_ROOT") && cat -- $(shell_quote "$path")"
}

do_pull() {
  local path local_target local_parent remote_source
  path="$(normalize_rel_path "$1")"
  reject_invalid_path "$path"
  reject_protected_path "$path"
  require_local_command rsync
  ensure_workspace_dirs

  local_target="$WORKSPACE_ROOT/$LOCAL_ROOT/$path"
  local_parent="$(dirname "$local_target")"
  remote_source="$(printf '%s@%s:%s/%s' "$USER_NAME" "$HOST" "$REMOTE_ROOT" "$path")"

  mkdir -p "$local_parent"
  log_operation "pull $path"

  if ! rsync -av "${rsync_excludes_pull[@]}" -e "ssh -p $PORT -o BatchMode=yes -o ConnectTimeout=10" "$remote_source" "$local_parent/"; then
    error "pull に失敗しました。接続先、対象 path、rsync の有無を確認してください。"
    exit 1
  fi
}

do_push() {
  local path local_source remote_parent remote_parent_path
  path="$(normalize_rel_path "$1")"
  reject_invalid_path "$path"
  reject_protected_path "$path"
  require_local_command rsync
  ensure_workspace_dirs

  local_source="$WORKSPACE_ROOT/$LOCAL_ROOT/$path"
  if [[ ! -e "$local_source" ]]; then
    error "ローカルに対象がありません: $local_source"
    exit 1
  fi

  remote_parent_path="$(dirname "$path")"
  if [[ "$remote_parent_path" == "." ]]; then
    remote_parent="$REMOTE_ROOT"
  else
    remote_parent="$REMOTE_ROOT/$remote_parent_path"
  fi

  log_operation "push $path"
  run_ssh "mkdir -p $(shell_quote "$remote_parent")"

  if ! rsync -av -e "ssh -p $PORT -o BatchMode=yes -o ConnectTimeout=10" "$local_source" "$(printf '%s@%s:%s/' "$USER_NAME" "$HOST" "$remote_parent")"; then
    error "push に失敗しました。接続先、対象 path、書き込み権限を確認してください。"
    exit 1
  fi
}

do_sync() {
  require_local_command rsync
  ensure_workspace_dirs
  log_operation "sync"

  if ! rsync -av "${rsync_excludes_sync[@]}" -e "ssh -p $PORT -o BatchMode=yes -o ConnectTimeout=10" "$(printf '%s@%s:%s/' "$USER_NAME" "$HOST" "$REMOTE_ROOT")" "$WORKSPACE_ROOT/$LOCAL_ROOT/"; then
    error "sync に失敗しました。接続先、remote_root、rsync の有無を確認してください。"
    exit 1
  fi
}

do_exec() {
  local command="$1"
  reject_dangerous_command "$command"
  require_local_command ssh
  ensure_workspace_dirs
  log_operation "exec $command"
  run_ssh "cd $(shell_quote "$REMOTE_ROOT") && $command"
}

do_diff() {
  require_local_command ssh
  ensure_workspace_dirs
  log_operation "diff"
  run_ssh "cd $(shell_quote "$REMOTE_ROOT") &&
echo '--- git diff --stat ---' &&
git diff --stat &&
echo &&
echo '--- git diff --name-only ---' &&
git diff --name-only &&
echo &&
echo '--- git diff ---' &&
git diff"
}

do_log() {
  ensure_workspace_dirs
  if [[ ! -f "$LOG_FILE" ]]; then
    echo "ログはまだありません"
    exit 0
  fi

  log_operation "log"
  cat "$LOG_FILE"
}

do_gui() {
  cat <<EOF
GUI companion:
  Start server: $PROJECT_ROOT/scripts/ui-serve.sh
  Then open:    http://127.0.0.1:8765

Multi-project workspace model:
  projects/<project>/config.yml
  projects/<project>/remote/
  projects/<project>/logs/

Tip:
  Create a workspace with ./scripts/ab.sh project init <name>
EOF
}

do_gui_serve() {
  "$PROJECT_ROOT/scripts/ui-serve.sh"
}

parse_global_options() {
  REMAINING_ARGS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)
        [[ $# -ge 2 ]] || { error "usage: ./scripts/ab.sh --project <name> ..."; exit 1; }
        ACTIVE_PROJECT="$2"
        shift 2
        ;;
      *)
        REMAINING_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

run_project_command() {
  local subcommand="${1:-}"

  case "$subcommand" in
    init)
      [[ $# -ge 2 ]] || { error "usage: ./scripts/ab.sh project init <name>"; exit 1; }
      do_project_init "$2"
      ;;
    list)
      do_project_list
      ;;
    use)
      [[ $# -ge 2 ]] || { error "usage: ./scripts/ab.sh project use <name>"; exit 1; }
      do_project_use "$2"
      ;;
    current)
      do_project_current
      ;;
    *)
      error "usage: ./scripts/ab.sh project {init|list|use|current}"
      exit 1
      ;;
  esac
}

main() {
  parse_global_options "$@"
  set -- "${REMAINING_ARGS[@]}"

  local command="${1:-help}"

  case "$command" in
    help|-h|--help)
      print_help
      exit 0
      ;;
    gui)
      do_gui
      exit 0
      ;;
    gui-serve)
      do_gui_serve
      exit 0
      ;;
    project)
      run_project_command "${@:2}"
      exit 0
      ;;
  esac

  set_workspace_context
  load_config
  build_ssh_opts

  case "$command" in
    status)
      do_status
      ;;
    ls)
      [[ $# -ge 2 ]] || { error "usage: ./scripts/ab.sh [--project <name>] ls <path>"; exit 1; }
      do_ls "$2"
      ;;
    tree)
      [[ $# -ge 2 ]] || { error "usage: ./scripts/ab.sh [--project <name>] tree <path>"; exit 1; }
      do_tree "$2"
      ;;
    cat)
      [[ $# -ge 2 ]] || { error "usage: ./scripts/ab.sh [--project <name>] cat <path>"; exit 1; }
      do_cat "$2"
      ;;
    pull)
      [[ $# -ge 2 ]] || { error "usage: ./scripts/ab.sh [--project <name>] pull <path>"; exit 1; }
      do_pull "$2"
      ;;
    push)
      [[ $# -ge 2 ]] || { error "usage: ./scripts/ab.sh [--project <name>] push <path>"; exit 1; }
      do_push "$2"
      ;;
    sync)
      do_sync
      ;;
    exec)
      [[ $# -ge 2 ]] || { error 'usage: ./scripts/ab.sh [--project <name>] exec "<command>"'; exit 1; }
      do_exec "$2"
      ;;
    diff)
      do_diff
      ;;
    log)
      do_log
      ;;
    *)
      error "不明なサブコマンドです: $command"
      print_help
      exit 1
      ;;
  esac
}

main "$@"
