# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

会議の録画動画・音声から文字起こしを行い、要約まで生成するパイプライン。
処理の本体は単一の Bash スクリプト [run_audio_scribe.sh](run_audio_scribe.sh) で、
`ffmpeg` → `whisperx` → `ollama` を順に呼び出す。Python パッケージは存在せず
(`pyproject.toml` の `dependencies = []`、`package = false`)、Python/Node のツールチェーンは
リンタ・フォーマッタ・spell check のためだけに導入されている。

## パイプライン

[run_audio_scribe.sh](run_audio_scribe.sh) は入力ファイルを位置引数で受け取る:

```
Usage: run_audio_scribe.sh [OPTIONS] <video-or-audio-file>

OPTIONS:
  -h, --help     ヘルプを表示
  -v, --verbose  set -x で詳細ログ

ENV:
  HF_TOKEN   HuggingFace トークン (話者分離に必要; 未設定時は dummy で続行し警告)
  MODEL      ollama モデル (既定: gemma4:12b-it-qat)
  API_URL    ollama API エンドポイント (既定: http://localhost:11434/api/generate)
  NUM_CTX    ollama のコンテキスト長 (トークン; 既定: 16384)
```

処理の流れ (`base` = 拡張子なしのファイル名、`video_dir` = 入力ファイルの親ディレクトリ):

1. `ffmpeg` で入力から音声抽出 → `data/interim/<base>.wav` (16kHz / mono / pcm_s16le)。
2. `whisperx` で WAV を文字起こし → `data/interim/<base>.srt`
   (model `large-v3-turbo`、`--diarize` で話者分離、`--language ja`、CPU/int8)。
   結果を `video_dir/<base>-asr.srt` へコピーして永続化。
3. `ollama` に 2 段階でテキストを渡す:
   - 校正: `data/interim/<base>.srt` → `data/interim/<base>-proofread.srt`、
     `video_dir/<base>-proofread.srt` へコピー。
   - 要約: `data/interim/<base>-proofread.srt` → `video_dir/<base>-summary.md` (Markdown)。
4. 正常完了後に `data/interim/<base>*` を削除 (中間ファイルのクリーンアップ)。

ollama へのプロンプトは外部 Markdown ファイル ([prompts/proofread.md](prompts/proofread.md)、
[prompts/summarize.md](prompts/summarize.md)) に記述し、`{{INPUT}}` プレースホルダに
書き起こしテキストが差し込まれる。リクエストは `jq --rawfile` + `curl --data-binary @file`
でファイル経由して送信する。リクエストの `options` には `temperature: 0` と `num_ctx`
(既定 16384) を指定する。校正は入力 SRT 全文を再生成するため、`num_ctx` が小さいと応答が
空になり得る (空応答は下記のガードで検出)。

レスポンスは `stream: true` でストリーミング受信する (生成完了まで何も表示されないのを避け、
進捗が見えるようにするため)。ollama は JSON Lines (1 行 1 JSON、各行に `.response` トークンと
`.done`) を返すので、`curl -sS --no-buffer` で受け取り、生ストリームを `tee` で一時ファイルに
保存しつつ、`jq -j --unbuffered '.response // empty'` でトークンだけ抽出して `tee` で標準エラー
(ライブ表示) と出力ファイルの両方へ流す。

検証は受信後にまとめて行う。API エラーはストリーム中の `.error` フィールドを持つ行で検出し
(`jq -se 'any(.[]; has("error"))'`)、トークンが 1 つも出なかった場合は出力ファイルが空になるため
`-s` で検出する。`jq -j` は末尾改行を付けないので、整合のため出力ファイルに改行を 1 つ追記する。

### 再開・スキップのロジック

チェックポイントは `video_dir` に保存され、再実行時に未完了ステップだけを処理できる
(存在判定は空ファイルを採用しないよう `-s`、すなわち「存在かつ非空」で行う):

- `video_dir/<base>-summary.md` が非空 → 最終結果あり、何もせず終了。
- `video_dir/<base>-asr.srt` が非空 → whisperx をスキップし interim へコピー。
- `video_dir/<base>-proofread.srt` が非空 → 校正をスキップし interim へコピー。

### HF_TOKEN

`HF_TOKEN` は環境変数から読み込む。未設定または空の場合は警告を出して `dummy` で続行するが、
話者分離は失敗しうる。実運用では `HF_TOKEN` を設定してから実行すること。

## データディレクトリ

`data/{raw,interim,processed}/` は中身を git 管理しない (`.gitkeep` のみ追跡、
[data/.gitignore](data/.gitignore))。`data/interim/` は作業領域として使用し、
パイプライン正常完了後に当該 `base` の中間ファイルが削除される。

## ツールとコマンド

ツールバージョンは [mise.toml](mise.toml) で固定 (ffmpeg, node, pnpm, python, uv)。
`.env` が mise 経由で読み込まれる。Python 仮想環境・依存は `uv` で管理する。

- Python lint: `uv run ruff check .`
- Python format: `uv run ruff format .`
- 型チェック: `uv run mypy .`
- テスト: `uv run pytest` (現状テストコードは未配置)
- spell check: `pnpm cspell lint --no-progress <files>`
- prettier (yaml): `npx prettier --check '**/*.{yml,yaml}'`

ruff は `select = ["ALL"]` で全ルール有効、`data/` と `.vscode` は除外。

## コミット時のフック

[lefthook.yml](lefthook.yml) の pre-commit でステージ済みファイルに対し format と lint を実行:
prettier (yaml)、ruff (format + `check --fix`)、shfmt (Bash 整形)、cspell の整列、
shellcheck (Bash 静的検査)、spell check。
新語は `.cspell.json` に追加する (フックがアルファベット順に整列する)。

## 注意

[docs/reports/2026-05-31-directory-structure.md](docs/reports/2026-05-31-directory-structure.md)
は `meet-digest` という別名で `config/` や `src/*.py`、launchd 連携を含む構想を記述しているが、
これは現状の実装と一致しない将来案。実態は上記の単一 Bash スクリプトである。
