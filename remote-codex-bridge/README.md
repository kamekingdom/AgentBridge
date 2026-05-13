# Remote Codex Bridge

Remote Codex Bridge は、ローカル PC A 上の Codex CLI から、SSH 越しにリモート PC B のプロジェクトを最小構成で扱うための Bash ツールです。Codex 自体は A で動作し、B では必要なファイルだけを確認・取得・編集反映・テスト実行します。

## 使う前提

- Codex CLI はローカル PC A で動作する
- リモート PC B には Codex や AI エージェントを入れない
- B のプロジェクトは SSH でアクセスできる
- ローカルには `remote/` 以下に、B の `remote_root` 配下の階層をなるべく保ったまま保存する
- テストやビルド、実行は B 上で `exec` を使って行う

## 構成

```text
remote-codex-bridge/
  README.md
  AGENTS.md
  config.example.yml
  config.yml
  .gitignore
  remote/
  logs/
  scripts/
    ab.sh
```

## config.yml の設定方法

`config.yml` は単純な key-value 形式です。まず `config.example.yml` を参考に、接続先の値へ書き換えてください。

```yaml
host: "your-remote-host"
port: 22
user: "your-user"
remote_root: "/home/your-user/project"
local_root: "remote"
```

- `host`: リモートホスト名または IP
- `port`: SSH ポート
- `user`: SSH ログインユーザー
- `remote_root`: B 上で作業対象にするプロジェクトルート
- `local_root`: ローカル保存先。通常は `remote`

## コマンド

### status

SSH 接続確認と、`remote_root` に入れるかの確認を行います。

```bash
./scripts/ab.sh status
```

内部では `pwd`、`git status --short`、`ls -la` を順に確認します。

### ls

リモートの `remote_root` 配下の一覧を表示します。

```bash
./scripts/ab.sh ls .
./scripts/ab.sh ls src
```

### tree

リモートの階層を確認します。`tree` が無ければ `find` で代替します。

```bash
./scripts/ab.sh tree .
./scripts/ab.sh tree src
```

### cat

リモートファイルを標準出力に表示します。

```bash
./scripts/ab.sh cat src/main.py
```

### pull

リモートのファイルまたはディレクトリを、ローカルの `remote/<path>` に取得します。階層構造はできるだけ維持されます。

```bash
./scripts/ab.sh pull src/main.py
./scripts/ab.sh pull src
./scripts/ab.sh pull train.py
```

例:

```text
remote_root/src/main.py
-> remote/src/main.py
```

`pull` では以下を除外します。

- `.git`
- `node_modules`
- `.venv`
- `venv`
- `__pycache__`
- `.pytest_cache`
- `.mypy_cache`
- `dist`
- `build`
- `outputs`
- `checkpoints`
- `wandb`
- `.env`
- `.env.local`
- `secrets`

### push

ローカルの `remote/<path>` を、リモートの `remote_root/<path>` に戻します。親ディレクトリがなければ自動作成します。

```bash
./scripts/ab.sh push src/main.py
./scripts/ab.sh push train.py
```

### sync

リモート全体をローカルの `remote/` へ同期します。大きいデータや秘密情報は除外します。

```bash
./scripts/ab.sh sync
```

`sync` では以下を除外します。

- `.git`
- `node_modules`
- `.venv`
- `venv`
- `__pycache__`
- `.pytest_cache`
- `.mypy_cache`
- `dist`
- `build`
- `data`
- `datasets`
- `outputs`
- `checkpoints`
- `wandb`
- `.env`
- `.env.local`
- `secrets`

### exec

リモートの `remote_root` で任意コマンドを実行します。

```bash
./scripts/ab.sh exec "git status"
./scripts/ab.sh exec "pytest"
./scripts/ab.sh exec "python train.py --epochs 1"
./scripts/ab.sh exec "npm test"
```

最小限の安全策として、`sudo`、`su`、`shutdown`、`reboot`、`systemctl`、`rm -rf /`、fork bomb は拒否します。

### diff

リモートで Git 差分を確認します。

```bash
./scripts/ab.sh diff
```

内部では `git diff --stat`、`git diff --name-only`、`git diff` を順に実行します。

### log

`logs/operations.log` に記録された実行ログを表示します。

```bash
./scripts/ab.sh log
```

## Codex CLI にどう指示するか

Codex には、「リモートを直接触らず、まず `./scripts/ab.sh status` を実行し、必要なファイルだけ pull して編集し、push してから exec でテストする」という前提で指示します。

例:

- `まず status と tree を見て、必要な Python ファイルだけ pull して修正してください`
- `remote/tests と remote/src を編集対象にして、push 後に pytest を実行してください`
- `train.py を pull して修正し、push 後に python train.py --epochs 1 を実行してください`

## Codex に使わせる想定の例

### 例1: Python のテスト修正

1. `./scripts/ab.sh status`
2. `./scripts/ab.sh tree .`
3. `./scripts/ab.sh pull tests/`
4. `./scripts/ab.sh pull src/`
5. `remote/src/...` を編集
6. `./scripts/ab.sh push src/...`
7. `./scripts/ab.sh exec "pytest"`

### 例2: 機械学習スクリプトの修正

1. `./scripts/ab.sh pull train.py`
2. `remote/train.py` を編集
3. `./scripts/ab.sh push train.py`
4. `./scripts/ab.sh exec "python train.py --epochs 1"`

### 例3: Web アプリのビルド確認

1. `./scripts/ab.sh sync`
2. `remote/...` を編集
3. `./scripts/ab.sh push <changed-file>`
4. `./scripts/ab.sh exec "npm test"`
5. `./scripts/ab.sh exec "npm run build"`

## セキュリティ上の注意

- `..` を含む path や絶対パスは拒否されます
- `.env`、`.env.local`、`secrets`、`~/.ssh` は `cat`、`pull`、`push` 対象にできません
- `exec` では明らかに危険なコマンドを最低限ブロックします
- すべての操作は `logs/operations.log` に追記されます
- `ssh`、`rsync` の失敗時は、接続情報や権限を見直してください
- このツールは最小構成のため、強固なサンドボックスや厳密なポリシーエンジンは含みません
