#!/usr/bin/env bash

set -Eeuo pipefail

readonly TARGET_MOV="./data/raw/target.mov"
readonly TARGET_WAV="./data/interim/target.wav"
readonly WHISPER_OUTPUT_DIR="./data/interim/"
readonly HF_TOKEN="dummy"

ffmpeg -i "$TARGET_MOV" -vn -acodec pcm_s16le -ar 16000 -ac 1 "$TARGET_WAV"

uv run whisperx "$TARGET_WAV" --output_dir "$WHISPER_OUTPUT_DIR" --model large-v3-turbo --diarize --output_format srt --device cpu --batch_size 4 --language ja --compute_type int8 --hf_token="$HF_TOKEN"

readonly MODEL="gemma4:e4b-it-qat"
readonly WHISPER_SRT="$WHISPER_OUTPUT_DIR/target.srt"
readonly OLLAMA_OUTPUT_DIR="./data/interim/"
readonly FORMATTED_OUTPUT="$OLLAMA_OUTPUT_DIR/target-formatted.srt"
readonly SUMMARY_OUTPUT="$OLLAMA_OUTPUT_DIR/target-summary.srt"
API_URL="http://localhost:11434/api/generate"

jq -Rs --arg model "$MODEL" '
{
  model: $model,
  stream: false,
  options: {
    temperature: 0
  },
  prompt: (
"以下は音声認識によるSRT形式の書き起こしです。

あなたの作業は「最小限の校正」のみです。
元の形式を厳密に維持してください。

厳守事項:
- SRTの番号、タイムスタンプ、話者ラベルは一切変更しない
- ブロックの順番、数、区切りを変更しない
- 発話内容だけを修正する
- 要約しない
- 言い換えない
- 内容を追加しない
- 内容を削除しない
- 文の順番を入れ替えない
- 複数ブロックを結合しない
- 1つのブロックを分割しない
- 推測で専門用語や固有名詞を置き換えない
- 不自然でも、意味が判別できない箇所は原文を残す
- 明らかな誤字、脱字、句読点のみ修正する
- 句読点の追加は最小限にする

修正してよいこと:
- 句読点の追加
- 明らかな誤字の修正
- 明らかに欠けている助詞の補完

修正してはいけない例:
- 「今日に回させていただきました」を「忙しなかったので」に変える
- 「ログインの阻止」を推測で別表現に変える
- 「昨日終了したいと思います」を勝手に「本日終了」に変える
- 話者ラベルやタイムスタンプを削除する

出力:
- 入力と同じSRT形式のみを出力する
- 説明、前置き、補足は出力しない

書き起こしテキスト:
---
" + . + "
---"
  )
}
' "$WHISPER_SRT" |
  curl -sS "$API_URL" \
    -H "Content-Type: application/json" \
    -d @- |
  jq -r '.response' >"$FORMATTED_OUTPUT"

jq -Rs --arg model "$MODEL" '
{
  model: $model,
  stream: false,
  options: {
    temperature: 0
  },
  prompt: (
"以下は会議の書き起こしを整形したテキストです。
会議内容が分かるように、簡潔に要約してください。

条件:
- 書き起こしにない内容は追加しない
- 推測しない
- 重要な内容は欠落させない
- 話された順番をできるだけ維持する
- TODO、決定事項、論点などに分類しない
- 固有名詞、日付、時刻、システム名は残す
- 不明な箇所は「不明瞭」と書く
- 要約ではあるが、話題単位の省略はしない
- 箇条書きの数は固定しない
- 会議内容に応じて、必要な数だけ箇条書きにする
- 1つの箇条書きには、原則として1つの話題だけを書く
- 複数の話題を無理に1つへまとめない
- 抽象的に言い換えすぎない
- 「議論した」「調査した」「検討した」「焦点を当てた」「求められた」などは、書き起こしから明確に分かる場合だけ使う
- 明確でない場合は「話した」「確認した」「触れた」と書く
- 「予定」「決定」「依頼」は、書き起こしから明確に分かる場合だけ使う
- 会議終了の挨拶だけの内容は、重要でなければ省略する

文体:
- 常体で書く
- 事実ベースで簡潔に書く

出力形式:

# 概要

会議全体を1〜2文で要約する。
抽象化しすぎず、主な話題が分かるように書く。

# 会話内容の要約

会話された順番に沿って、話題ごとに箇条書きで要約する。
箇条書きの数は固定せず、会議内容に応じて必要な数だけ出力する。

対象テキスト:
---
{{INPUT}}
---

対象テキスト:
---
" + . + "
---"
  )
}
' "$FORMATTED_OUTPUT" |
  curl -sS "$API_URL" \
    -H "Content-Type: application/json" \
    -d @- |
  jq -r '.response' >"$SUMMARY_OUTPUT"
