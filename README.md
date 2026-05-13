# Remote Codex Bridge

Remote Codex Bridge は、ローカル PC A で動く Codex CLI が、SSH 越しに複数のリモート案件を扱うための最小ツールです。各案件は `projects/<project>/` を専用ワークスペースとして持ち、その中に設定、取得ファイル、ログを閉じ込めます。

## Remote Codex Bridge とは何か

- Codex は A で動く
- B には Codex や AI エージェントを入れない
- 案件ごとに `projects/<name>/` を作業スペースとして分離する
- 必要なファイルだけを `projects/<name>/remote/` に pull する
- ローカル編集後に push で戻す
- テストやビルドは SSH 越しに B 上で実行する

## 使う前提

- ローカル PC A で `bash`、`ssh`、`rsync` が使える
- リモート PC B に SSH 接続できる
- 案件ごとに `remote_root` が異なる可能性がある
- 操作の中心は `./scripts/ab.sh`
- GUI は補助導線で、生成されたコマンドを Codex やターミナルで使う

## 構成

```text
.
├── README.md
├── AGENTS.md
├── config.example.yml
├── scripts/
│   └── ab.sh
├── projects/
│   └── <project>/
│       ├── config.yml
│       ├── remote/
│       └── logs/
└── ui/
    ├── index.html
    ├── app.js
    └── styles.css
```

## プロジェクトごとのワークスペース

各案件は `projects/<project>/` が作業スペースです。

- `projects/<project>/config.yml`: その案件専用の接続設定
- `projects/<project>/remote/`: pull や sync で取得したローカルミラー
- `projects/<project>/logs/`: その案件の操作ログ

例:

```text
projects/client-a/config.yml
projects/client-a/remote/src/main.py
projects/client-a/logs/operations.log

projects/ml-lab/config.yml
projects/ml-lab/remote/train.py
projects/ml-lab/logs/operations.log
```

## config.yml の設定方法

`config.example.yml` をテンプレートとして、各案件の `projects/<project>/config.yml` に配置します。

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
- `local_root`: ワークスペース内のローカル保存先。通常は `remote`

## プロジェクト管理コマンド

### project init <name>

新しい案件ワークスペースを作成します。

```bash
./scripts/ab.sh project init client-a
```

作成されるもの:

- `projects/client-a/config.yml`
- `projects/client-a/remote/`
- `projects/client-a/logs/`

### project list

案件ワークスペース一覧を表示します。

```bash
./scripts/ab.sh project list
```

### project use <name>

現在の作業対象プロジェクトを切り替えます。

```bash
./scripts/ab.sh project use client-a
```

### project current

現在選択中のプロジェクトとワークスペースを表示します。

```bash
./scripts/ab.sh project current
```

## GUI の使い方

GUI は ChatGPT 風の画面です。左側でプロジェクトを管理し、右側でチャット形式で指示を送ると、ローカルの Codex CLI が応答します。

重要:

- `ui/index.html` を直接開くのではなく、ローカル UI サーバー経由で使います
- 送信は `Command+Enter` です
- 返答はローカルの `codex exec` を使って生成されます

起動手順:

```bash
./scripts/ui-serve.sh
```

ブラウザで以下を開きます。

```text
http://127.0.0.1:8765
```

補助コマンド:

```bash
./scripts/ab.sh gui
./scripts/ab.sh gui-serve
```

## 通常コマンド

通常コマンドは、`project use` で選んだ案件か、`--project <name>` を付けた案件に対して動作します。

### status

```bash
./scripts/ab.sh status
./scripts/ab.sh --project client-a status
```

SSH 接続確認、`remote_root` に入れるかの確認、`pwd`、`git status --short`、`ls -la` をまとめて実行します。

### ls

```bash
./scripts/ab.sh --project client-a ls .
./scripts/ab.sh --project client-a ls src
```

### tree

```bash
./scripts/ab.sh --project client-a tree .
./scripts/ab.sh --project client-a tree src
```

`tree` が無ければ `find` で代替します。

### cat

```bash
./scripts/ab.sh --project client-a cat src/main.py
```

### pull

```bash
./scripts/ab.sh --project client-a pull src/main.py
./scripts/ab.sh --project client-a pull src
./scripts/ab.sh --project client-a pull train.py
```

例:

```text
remote_root/src/main.py
-> projects/client-a/remote/src/main.py
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

```bash
./scripts/ab.sh --project client-a push src/main.py
./scripts/ab.sh --project client-a push train.py
```

ローカルの `projects/<project>/remote/<path>` をリモートへ戻します。

### sync

```bash
./scripts/ab.sh --project client-a sync
```

リモート全体を `projects/<project>/remote/` へ同期します。大きいデータや秘密情報は除外します。

除外:

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

```bash
./scripts/ab.sh --project client-a exec "git status"
./scripts/ab.sh --project client-a exec "pytest"
./scripts/ab.sh --project client-a exec "python train.py --epochs 1"
./scripts/ab.sh --project client-a exec "npm test"
```

### diff

```bash
./scripts/ab.sh --project client-a diff
```

### log

```bash
./scripts/ab.sh --project client-a log
```

案件ごとの `projects/<project>/logs/operations.log` を表示します。

## Codex CLI にどう指示するか

Codex には、「対象プロジェクトを明示し、そのワークスペースだけを使って作業する」という前提で指示します。

例:

- `client-a を対象に status と tree を見て、必要な Python ファイルだけ pull して修正してください`
- `ml-lab を対象に train.py を pull して修正し、push 後に python train.py --epochs 1 を実行してください`
- `web-admin を対象に sync 後、changed file だけ push して npm test と npm run build を実行してください`

## Codex に使わせる想定の例

### 例1: Python のテスト修正

1. `./scripts/ab.sh project use client-a`
2. `./scripts/ab.sh status`
3. `./scripts/ab.sh tree .`
4. `./scripts/ab.sh pull tests/`
5. `./scripts/ab.sh pull src/`
6. `projects/client-a/remote/src/...` を編集
7. `./scripts/ab.sh push src/...`
8. `./scripts/ab.sh exec "pytest"`

### 例2: 機械学習スクリプトの修正

1. `./scripts/ab.sh --project ml-lab pull train.py`
2. `projects/ml-lab/remote/train.py` を編集
3. `./scripts/ab.sh --project ml-lab push train.py`
4. `./scripts/ab.sh --project ml-lab exec "python train.py --epochs 1"`

### 例3: Web アプリのビルド確認

1. `./scripts/ab.sh --project web-admin sync`
2. `projects/web-admin/remote/...` を編集
3. `./scripts/ab.sh --project web-admin push <changed-file>`
4. `./scripts/ab.sh --project web-admin exec "npm test"`
5. `./scripts/ab.sh --project web-admin exec "npm run build"`

## セキュリティ上の注意

- `..` を含む path や絶対パスは拒否されます
- `.env`、`.env.local`、`secrets`、`~/.ssh` は `cat`、`pull`、`push` 対象にできません
- `exec` では明らかに危険なコマンドを最低限ブロックします
- すべての操作は案件ごとの `logs/operations.log` に追記されます
- `ssh`、`rsync` の失敗時は、接続情報や権限、コマンドの存在を見直してください
- GUI は補助用であり、実際の処理は `scripts/ab.sh` が行います
