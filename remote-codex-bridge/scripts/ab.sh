#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config.yml"
LOG_FILE="$PROJECT_ROOT/logs/operations.log"

HOST=""
PORT=""
USER_NAME=""
REMOTE_ROOT=""
LOCAL_ROOT=""

print_help() {
  cat <<'EOF'
Remote Codex Bridge

Usage:
  ./scripts/ab.sh help
  ./scripts/ab.sh status
  ./scripts/ab.sh ls <path>
  ./scripts/ab.sh tree <path>
  ./scripts/ab.sh cat <path>
  ./scripts/ab.sh pull <path>
  ./scripts/ab.sh push <path>
  ./scripts/ab.sh sync
  ./scripts/ab.sh exec "<command>"
  ./scripts/ab.sh diff
  ./scripts/ab.sh log

Examples:
  ./scripts/ab.sh status
  ./scripts/ab.sh ls src
  ./scripts/ab.sh tree .
  ./scripts/ab.sh cat src/main.py
  ./scripts/ab.sh pull src/main.py
  ./scripts/ab.sh push src/main.py
  ./scripts/ab.sh sync
  ./scripts/ab.sh exec "pytest"
  ./scripts/ab.sh diff
EOF
}

error() {
  echo "Error: $*" >&2
}

log_operation() {
  mkdir -p "$(dirname "$LOG_FILE")"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
}

shell_quote() {
  local value="${1:-}"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    error "config.yml が見つかりません: $CONFIG_FILE"
    exit 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ -z "${line//[[:space:]]/}" ]] && continue

    local key="${line%%:*}"
    local value="${line#*:}"
    key="$(printf '%s' "$key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
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
    error "config.yml の必須キーが不足しています"
    exit 1
  fi
}

ssh_target() {
  printf '%s@%s' "$USER_NAME" "$HOST"
}

ssh_opts=()

build_ssh_opts() {
  ssh_opts=(-p "$PORT" -o BatchMode=yes -o ConnectTimeout=10)
}

run_ssh() {
  local remote_script="$1"

  if ! ssh "${ssh_opts[@]}" "$(ssh_target)" "sh -lc $(shell_quote "$remote_script")"; then
    error "SSH 実行に失敗しました。接続先、鍵、remote_root を確認してください。"
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

  case "$path" in
    ..|../*|*/../*|*/..)
      error "'..' を含む path は指定できません: $path"
      exit 1
      ;;
  esac

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

ensure_local_root() {
  mkdir -p "$PROJECT_ROOT/$LOCAL_ROOT"
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

do_status() {
  log_operation "status"
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
  log_operation "ls $path"
  run_ssh "cd $(shell_quote "$REMOTE_ROOT") && ls -la -- $(shell_quote "$path")"
}

do_tree() {
  local path
  path="$(normalize_rel_path "$1")"
  reject_invalid_path "$path"
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
  log_operation "cat $path"
  run_ssh "cd $(shell_quote "$REMOTE_ROOT") && cat -- $(shell_quote "$path")"
}

do_pull() {
  local path local_target local_parent remote_source
  path="$(normalize_rel_path "$1")"
  reject_invalid_path "$path"
  reject_protected_path "$path"
  ensure_local_root

  local_target="$PROJECT_ROOT/$LOCAL_ROOT/$path"
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

  local_source="$PROJECT_ROOT/$LOCAL_ROOT/$path"
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
  ensure_local_root
  log_operation "sync"

  if ! rsync -av "${rsync_excludes_sync[@]}" -e "ssh -p $PORT -o BatchMode=yes -o ConnectTimeout=10" "$(printf '%s@%s:%s/' "$USER_NAME" "$HOST" "$REMOTE_ROOT")" "$PROJECT_ROOT/$LOCAL_ROOT/"; then
    error "sync に失敗しました。接続先、remote_root、rsync の有無を確認してください。"
    exit 1
  fi
}

do_exec() {
  local command="$1"
  reject_dangerous_command "$command"
  log_operation "exec $command"
  run_ssh "cd $(shell_quote "$REMOTE_ROOT") && $command"
}

do_diff() {
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
  if [[ ! -f "$LOG_FILE" ]]; then
    echo "ログはまだありません"
    exit 0
  fi

  log_operation "log"
  cat "$LOG_FILE"
}

main() {
  local command="${1:-help}"

  case "$command" in
    help|-h|--help)
      print_help
      exit 0
      ;;
  esac

  load_config
  build_ssh_opts

  case "$command" in
    status)
      do_status
      ;;
    ls)
      [[ $# -ge 2 ]] || { error "usage: ./scripts/ab.sh ls <path>"; exit 1; }
      do_ls "$2"
      ;;
    tree)
      [[ $# -ge 2 ]] || { error "usage: ./scripts/ab.sh tree <path>"; exit 1; }
      do_tree "$2"
      ;;
    cat)
      [[ $# -ge 2 ]] || { error "usage: ./scripts/ab.sh cat <path>"; exit 1; }
      do_cat "$2"
      ;;
    pull)
      [[ $# -ge 2 ]] || { error "usage: ./scripts/ab.sh pull <path>"; exit 1; }
      do_pull "$2"
      ;;
    push)
      [[ $# -ge 2 ]] || { error "usage: ./scripts/ab.sh push <path>"; exit 1; }
      do_push "$2"
      ;;
    sync)
      do_sync
      ;;
    exec)
      [[ $# -ge 2 ]] || { error 'usage: ./scripts/ab.sh exec "<command>"'; exit 1; }
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
