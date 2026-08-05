# Audio Scribe

## Overview

会議録画の動画や音声から文字起こしを行い、要約作成まで実施するスクリプトです。
ffmpeg, whisperx, ollama を利用して書き起こしから要約作成まで実施します。

## Prerequisites

- [mise](https://mise.jdx.dev/): ffmpeg や whisperx などの依存ツールは mise が
  導入するため、ホストにあらかじめ必要なのは mise のみです。
- HuggingFace トークン: 話者分離に必要です。pyannote 系モデルの利用規約に
  同意したアカウントのトークンを用意してください。
- LLM agent (いずれか一方):
  - [ollama](https://ollama.com/) (既定): ローカルで起動し、既定モデル
    `gemma4:4b-it-qat` と `gemma4:12b-it-qat` を事前に pull しておきます。
  - claude CLI: `--agent claude` を指定する場合に必要です。

## Setup

ツールと git フックを導入します。

```sh
mise install
mise run setup
```

リポジトリ直下に `.env` を作成し、HuggingFace トークンを記載します
(mise が起動時に読み込みます)。

```sh
HF_TOKEN=hf_xxxxxxxxxxxxxxxx
```

## Usage

動画または音声ファイルを渡すと、文字起こしと要約を生成します。

```sh
./run_audio_scribe.sh path/to/meeting.mov
```

主要オプション:

- `-a, --agent AGENT`: LLM agent (`ollama` または `claude`、既定: `ollama`)
- `--proofread-model MODEL`: 校正用モデル
  (既定: ollama は `gemma4:4b-it-qat`、claude は `haiku`)
- `--summarize-model MODEL`: 要約用モデル
  (既定: ollama は `gemma4:12b-it-qat`、claude は `sonnet`)
- `-v, --verbose`: 詳細ログを出力する

環境変数:

- `HF_TOKEN`: HuggingFace トークン。話者分離に必要で、未設定の場合は警告を
  出して dummy で続行しますが話者分離は失敗しえます。
- `API_URL`: ollama API エンドポイント
  (既定: `http://localhost:11434/api/generate`)
- `NUM_CTX`: ollama のコンテキスト長 (トークン、既定: 131072)

ディレクトリ以下の `.mov` ファイルをまとめて処理する場合はバッチ用
スクリプトを使います。1 件が失敗しても残りの処理を継続し、オプションと
環境変数はそのまま run_audio_scribe.sh へ引き継がれます。

```sh
./run_audio_scribe_batch.sh path/to/recordings
```

出力ファイルは入力ファイルと同じディレクトリに生成されます。

- `<入力名>-asr.srt`: 文字起こし結果 (whisperx、話者分離つき)
- `<入力名>-proofread.srt`: 校正済みの文字起こし
- `<入力名>-summary.md`: 要約 (Markdown)

これらのファイルが非空で存在するステップは、再実行時にスキップされます。

## Development

lint / format / test は mise タスクに統一されています。

```sh
mise run lint
mise run format
mise run test
```

pre-commit フック (lefthook) は `mise run setup` で導入され、コミット時に
format / lint / test を実行します。spell check で未知語が報告された場合は
`.cspell.json` の words に追加してください (フックがアルファベット順に
整列します)。
