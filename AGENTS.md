# AGENTS.md

このリポジトリでは、リモート PC B を直接編集せず、必ず `scripts/ab.sh` を使って作業します。案件ごとの作業スペースは `projects/<project>/` です。

## 基本ルール

- 最初に対象案件を `./scripts/ab.sh project use <name>` で選ぶか、各コマンドに `--project <name>` を付ける
- 新しい案件は `./scripts/ab.sh project init <name>` で作成する
- 最初の確認は `./scripts/ab.sh status` を実行して、接続と `remote_root` を確認する
- リモート構造を知るには `./scripts/ab.sh tree .` を使う
- 必要なファイルだけ `./scripts/ab.sh pull <path>` で取得する
- ローカルでは `projects/<project>/remote/<path>` を編集する
- 編集後は `./scripts/ab.sh push <path>` でリモートへ戻す
- テストやビルドは `./scripts/ab.sh exec "<command>"` で B 上で実行する
- GUI で確認したいときは `ui/index.html` を開き、対象案件名を入れて生成されたコマンドを使う

## 読まないもの

- `.env`
- `.env.local`
- `secrets`
- `~/.ssh`

## 同期しないもの

- `data`
- `datasets`
- `checkpoints`
- 大きな生成物やキャッシュ

## 安全方針

- 破壊的操作は避ける
- 不要な全量同期は避け、必要なファイルだけ pull する
- リモートでの確認は `status`、`tree`、`ls`、`cat`、`diff` を優先する
- 変更後は `push` してから `exec` で検証する
- 作業ファイルやログは案件ごとの `projects/<project>/` に閉じ込める
