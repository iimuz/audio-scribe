# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

会議の録画動画・音声から文字起こしを行い、要約まで生成するパイプライン。
処理の本体は単一の Bash スクリプト [run_audio_scribe.sh](run_audio_scribe.sh) で、
`ffmpeg` → `whisperx` → LLM agent (既定: ollama) を順に呼び出す。Python パッケージは存在せず、
Node のツールチェーンはリンタ・フォーマッタ・spell check のためだけに導入されている。

## パイプライン

[run_audio_scribe.sh](run_audio_scribe.sh) は入力ファイルを位置引数で受け取る:

```text
Usage: run_audio_scribe.sh [OPTIONS] <video-or-audio-file>

OPTIONS:
  -h, --help         ヘルプを表示
  -v, --verbose      set -x で詳細ログ
  -a, --agent AGENT  LLM agent (ollama | claude; 既定: ollama)
  --proofread-model MODEL   校正用モデル
                            (既定: ollama=gemma4:4b-it-qat, claude=haiku)
  --summarize-model MODEL   要約用モデル
                            (既定: ollama=gemma4:12b-it-qat, claude=sonnet)

ENV:
  HF_TOKEN   HuggingFace トークン (話者分離に必要; 未設定時は dummy で続行し警告)
  API_URL    ollama API エンドポイント (既定: http://localhost:11434/api/generate)
  NUM_CTX    ollama のコンテキスト長 (トークン; 既定: 131072)
```

処理の流れ (`base` = 拡張子なしのファイル名、`video_dir` = 入力ファイルの親ディレクトリ):

1. `ffmpeg` で入力から音声抽出 → `data/interim/<base>.wav` (16kHz / mono / pcm_s16le)。
2. `whisperx` で WAV を文字起こし → `data/interim/<base>.srt`
   (model `large-v3-turbo`、`--diarize` で話者分離、`--language ja`、CPU/int8)。
   結果を `video_dir/<base>-asr.srt` へコピーして永続化。
3. LLM agent (既定: ollama、`--agent claude` で claude CLI) に 2 段階でテキストを渡す。
   校正と要約はそれぞれ別モデルを使う (`--proofread-model` / `--summarize-model`
   で個別に指定可能):
   - 校正: `data/interim/<base>.srt` → `data/interim/<base>-proofread.srt`、
     `video_dir/<base>-proofread.srt` へコピー。軽量モデルを使用
     (既定: ollama=`gemma4:4b-it-qat`, claude=`haiku`)。
   - 要約: `data/interim/<base>-proofread.srt` → `video_dir/<base>-summary.md` (Markdown)。
     通常モデルを使用 (既定: ollama=`gemma4:12b-it-qat`, claude=`sonnet`)。
4. 正常完了後に `data/interim/<base>*` を削除 (中間ファイルのクリーンアップ)。

ollama へのプロンプトは外部 Markdown ファイル ([prompts/proofread.md](prompts/proofread.md)、
[prompts/summarize.md](prompts/summarize.md)) に記述し、`{{INPUT}}` プレースホルダに
書き起こしテキストが差し込まれる。リクエストは `jq --rawfile` + `curl --data-binary @file`
でファイル経由して送信する。リクエストの `options` には `temperature: 0` と `num_ctx`
(既定 131072) を指定する。校正は入力 SRT 全文を再生成するため、`num_ctx` が小さいと応答が
空になり得る (空応答は下記のガードで検出)。

レスポンスは `stream: true` でストリーミング受信する (生成完了まで何も表示されないのを避け、
進捗が見えるようにするため)。ollama は JSON Lines (1 行 1 JSON、各行に `.response` トークンと
`.done`) を返すので、`curl -sS --no-buffer` で受け取り、生ストリームを `tee` で一時ファイルに
保存しつつ、`jq -j --unbuffered '.response // empty'` でトークンだけ抽出して `tee` で標準エラー
(ライブ表示) と出力ファイルの両方へ流す。

検証は受信後にまとめて行う。API エラーはストリーム中の `.error` フィールドを持つ行で検出し
(`jq -se 'any(.[]; has("error"))'`)、トークンが 1 つも出なかった場合は出力ファイルが空になるため
`-s` で検出する。`jq -j` は末尾改行を付けないので、整合のため出力ファイルに改行を 1 つ追記する。

`--agent claude` を指定した場合は ollama API の代わりに `claude -p` を実行する。
プロンプトは stdin 経由で渡し、モデルはステップごとに異なる値
(`--proofread-model` 既定 `haiku` / `--summarize-model` 既定 `sonnet`) を
`claude -p --model` に渡す。effort はセッション設定に依存させないため常に
`--effort high` を付与する。出力はストリーミングせず完了時にまとめて受信する。
バックエンドは `--safe-mode --tools ""` (リポジトリカスタマイズなしのサンドボックス化) と
`--system-prompt` による完全置換 (このリポジトリへの一切の認識を排除し、純粋なテキスト変換にする)
で実行され、さらに防御的な `strip_markdown_fence` 後処理でフェンス行を除去したうえで、
終了コードと出力ファイル非空 (`-s`) で検証する。

### 再開・スキップのロジック

チェックポイントは `video_dir` に保存され、再実行時に未完了ステップだけを処理できる
(存在判定は空ファイルを採用しないよう `-s`、すなわち「存在かつ非空」で行う):

- `video_dir/<base>-summary.md` が非空 → 最終結果あり、何もせず終了。
- `video_dir/<base>-asr.srt` が非空 → whisperx をスキップし interim へコピー。
- `video_dir/<base>-proofread.srt` が非空 → 校正をスキップし interim へコピー。

### HF_TOKEN

`HF_TOKEN` は環境変数から読み込む。未設定または空の場合は警告を出して `dummy` で続行するが、
話者分離は失敗しうる。実運用では `HF_TOKEN` を設定してから実行すること。

## launchd による定期実行

macOS では [setup_launchd.sh](setup_launchd.sh) が
[com.iimuz.audio-scribe.plist.template](com.iimuz.audio-scribe.plist.template) を描画して
`~/Library/LaunchAgents/com.iimuz.audio-scribe.plist` に配置し、launchd で
`run_audio_scribe_batch.sh` を毎日定時実行する (`mise run launchd:install` /
`mise run launchd:uninstall`)。実行ログは `mise run launchd:logs` で追跡できる。

- plist は `mise exec -- bash -c 'exec ./run_audio_scribe_batch.sh ${AUDIO_SCRIBE_AGENT:+--agent "$AUDIO_SCRIBE_AGENT"} "${AUDIO_SCRIBE_TARGET_DIR:?...}"'`
  を WorkingDirectory=リポジトリで起動する。mise が .env とツール PATH を解決するため、
  対象ディレクトリ (`AUDIO_SCRIBE_TARGET_DIR`) と LLM agent (`AUDIO_SCRIBE_AGENT`、任意、
  既定 ollama) は実行時に .env から解決され、変更に再インストールは不要。`${VAR:+...}` を
  意図的に引用符で囲まないのは、未設定時に空文字列の引数を渡さないためであり、
  agent の値は ollama / claude のみで空白を含まないため単語分割は問題にならない。
- スケジュール時刻 (`AUDIO_SCRIBE_SCHEDULE_HOUR` 既定 3 / `AUDIO_SCRIBE_SCHEDULE_MINUTE` 既定 0) は
  インストール時に plist へ埋め込まれるため、変更時は `mise run launchd:install` の再実行が必要である。
- 標準出力・標準エラーは `~/Library/Logs/audio-scribe.log` へ追記される。ジョブ状態は
  `launchctl print gui/$(id -u)/com.iimuz.audio-scribe` で確認できる。
- launchd は同一ラベルのジョブ実行中は次回起動をスキップするためロック機構は持たない。
- テスト (`tests/setup_launchd.bats`) は描画・検証の純粋関数のみを対象とし、
  launchctl / plutil / mise には依存しない (CI は ubuntu のため)。

## データディレクトリ

`data/{raw,interim,processed}/` は中身を git 管理しない (`.gitkeep` のみ追跡、
[data/.gitignore](data/.gitignore))。`data/interim/` は作業領域として使用し、
パイプライン正常完了後に当該 `base` の中間ファイルが削除される。

## ツールとコマンド

ツールバージョンは [mise.toml](mise.toml) で固定
(bats, ffmpeg, node, pnpm, shellcheck, shfmt, taplo, uv, whisperx)。
`.env` が mise 経由で読み込まれる。`uv` は whisperx (pipx バックエンド) の
インストールに使用する。lint / format の入口は mise タスクに統一している。

- セットアップ: `mise run setup` (pnpm install と lefthook install)
- クリーンアップ: `mise run clean` (node_modules の削除)
- format: `mise run format` (shfmt、prettier (yaml / markdown)、taplo (toml)、
  `.cspell.json` の words 整列)
- format 検査: `mise run format:check`
- lint: `mise run lint` (shellcheck、markdownlint-cli2、prettier --check
  (yaml / markdown)、taplo --check、cspell)
- test: `mise run test` (bats による `tests/*.bats` の実行)
- launchd: `mise run launchd:install` / `mise run launchd:uninstall` (定期実行の
  導入・解除)、`mise run launchd:logs` (実行ログの追跡)

粒度別タスク (`format:sh` / `format:yaml` / `format:md` / `format:toml` /
`lint:sh` / `lint:md` / `lint:cspell`) はファイルを引数に取れる
(例: `mise run format:sh run_audio_scribe.sh`)。`format:cspell` と `test:sh` のみ
引数を取らず、それぞれ常に `.cspell.json` の words 整列と全 bats スイート実行を行う。

## コミット時のフック

[lefthook.yml](lefthook.yml) の pre-commit でステージ済みファイルに対し format、lint、test の各ジョブを順次実行する (format / lint ジョブ内のサブジョブはそれぞれ並列実行):
prettier (yaml)、shfmt (Bash 整形)、markdown (Markdown 整形)、toml (TOML 整形)、
cspell 辞書 (`.cspell.json`) の整列、shellcheck (Bash 静的検査)、prettier-md-check
(Markdown 整形検査)、markdownlint (Markdown 静的検査)、taplo-check (TOML 整形検査)、
spell check。
各ジョブは mise の粒度別タスクを呼び出すため、コマンド定義は
[mise.toml](mise.toml) に一元化されている。
staged files を引数として渡すのは cspell 辞書整列と test 以外のジョブで、
辞書整列は `mise run format:cspell` を無引数で呼び、test も無引数で `mise run test:sh`
を呼ぶ (bats 全件実行)。新語は `.cspell.json` に追加する (フックがアルファベット順に整列する)。

## CI

[.github/workflows/ci.yml](.github/workflows/ci.yml) が pull_request と main への
push をトリガーに lint (`mise run lint`)、format (`mise run format:check`)、
test (`mise run test`) を並列実行し、`status-check` ジョブが全ジョブの結果を集約する
(branch protection の required check は `status-check` を想定)。ツール導入は
jdx/mise-action で行い、CI に不要な重量ツール (`pipx:whisperx` / `ffmpeg` / `uv`) は
`MISE_DISABLE_TOOLS` で無効化する。ランナーは `ubuntu-24.04-arm`。action は commit
SHA でピン留めする。

main への push でも実行するのは、GitHub Actions のキャッシュがブランチスコープで
隔離されているため。pull_request の実行では merge ref (`refs/pull/N/merge`) の
スコープにしかキャッシュを書けず、default branch のスコープにキャッシュを作れるのは
push などのトリガーに限られる。これがないと新規 PR は毎回ツールを再インストールする
ことになる。mise-action のツールキャッシュは既定で有効 (`cache: true`) で、キーは
mise.toml の内容ハッシュから生成されるため個別設定は不要。

## Renovate

[.github/workflows/renovate.yml](.github/workflows/renovate.yml) が self-hosted
Renovate (renovatebot/github-action) を週次 (土曜 15:00 UTC) と
workflow_dispatch (log_level を choice 入力で指定可能) で実行する。
設定は [renovate.json](renovate.json) にあり、mise ツール・npm
devDependencies・GitHub Actions を更新対象とする。major / minor は種別
(github-actions / npm / mise / other) ごとにグルーピングし、patch / pin /
digest は automerge する (branch protection の required check である
status-check の通過が前提)。minimumReleaseAge は 14 days (pin / digest は
0 days)。デフォルトの GITHUB_TOKEN では Renovate の PR で CI がトリガー
されないため、repo scope (workflow 含む) の PAT をリポジトリ secret
RENOVATE_TOKEN に登録して使う。

## 注意

[docs/reports/2026-05-31-directory-structure.md](docs/reports/2026-05-31-directory-structure.md)
は `meet-digest` という別名で `config/` や `src/*.py`、launchd 連携を含む構想を記述しているが、
これは現状の実装と一致しない将来案。実態は上記の単一 Bash スクリプトである。
