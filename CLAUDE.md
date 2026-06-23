# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

会議の録画動画・音声から文字起こしを行い、要約まで生成するパイプライン。
処理の本体は単一の Bash スクリプト [run_audio_scribe.sh](run_audio_scribe.sh) で、
`ffmpeg` → `whisperx` → `ollama` を順に呼び出す。Python パッケージは存在せず
(`pyproject.toml` の `dependencies = []`、`package = false`)、Python/Node のツールチェーンは
リンタ・フォーマッタ・spell check のためだけに導入されている。

## パイプライン

[run_audio_scribe.sh](run_audio_scribe.sh) は固定パスで以下を実行する (引数なし):

1. `ffmpeg` で `data/raw/target.mov` から音声抽出 → `data/interim/target.wav`
   (16kHz / mono / pcm_s16le)。
2. `whisperx` で WAV を文字起こし → `data/interim/target.srt`
   (model `large-v3-turbo`、`--diarize` で話者分離、`--language ja`、CPU/int8)。
   話者分離は HuggingFace トークンが必要で、スクリプト内 `HF_TOKEN` は `dummy` 固定のため
   実運用では差し替えが必要。
3. `ollama` (`http://localhost:11434/api/generate`) に SRT を渡して 2 段階処理:
   - 校正: `target.srt` → `target-formatted.srt` (最小限の校正のみ、形式・話者ラベル・
     タイムスタンプは厳守で変更しない)
   - 要約: `target-formatted.srt` → `target-summary.srt`
   プロンプトは `jq -Rs` で JSON に埋め込み、`curl` で送信、レスポンスは `jq -r '.response'`
   で取り出す。モデルは `MODEL` 変数 (現状 `gemma4:e4b-it-qat`) で指定。

パス・モデル・プロンプトはすべてスクリプト先頭の `readonly` 変数とヒアドキュメントに
ハードコードされている。挙動を変えるときはここを編集する。

## データディレクトリ

`data/{raw,interim,processed}/` は中身を git 管理しない (`.gitkeep` のみ追跡、
[data/.gitignore](data/.gitignore))。入力は `data/raw/`、中間生成物は `data/interim/`。

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
prettier (yaml)、ruff (format + `check --fix`)、cspell の整列、spell check。
新語は `.cspell.json` に追加する (フックがアルファベット順に整列する)。

## 注意

[docs/reports/2026-05-31-directory-structure.md](docs/reports/2026-05-31-directory-structure.md)
は `meet-digest` という別名で `config/` や `src/*.py`、launchd 連携を含む構想を記述しているが、
これは現状の実装と一致しない将来案。実態は上記の単一 Bash スクリプトである。
