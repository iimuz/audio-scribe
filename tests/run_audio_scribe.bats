#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../run_audio_scribe.sh"
}

@test "has_checkpoint: 存在しないファイルは未完了" {
  run has_checkpoint "$BATS_TEST_TMPDIR/missing.srt"
  [ "$status" -ne 0 ]
}

@test "has_checkpoint: 空ファイルは未完了" {
  touch "$BATS_TEST_TMPDIR/empty.srt"
  run has_checkpoint "$BATS_TEST_TMPDIR/empty.srt"
  [ "$status" -ne 0 ]
}

@test "has_checkpoint: 非空ファイルは完了" {
  echo "content" >"$BATS_TEST_TMPDIR/done.srt"
  run has_checkpoint "$BATS_TEST_TMPDIR/done.srt"
  [ "$status" -eq 0 ]
}

@test "strip_markdown_fence: 両端のフェンス行を除去する" {
  local file="$BATS_TEST_TMPDIR/fenced.srt"
  printf '%s\n' '```srt' 'line1' 'line2' '```' >"$file"

  run strip_markdown_fence "$file"
  [ "$status" -eq 0 ]
  [ "$(cat "$file")" = "$(printf 'line1\nline2')" ]
}

@test "strip_markdown_fence: フェンスなし入力は変更しない" {
  local file="$BATS_TEST_TMPDIR/plain.srt"
  printf '%s\n' 'line1' 'line2' >"$file"

  run strip_markdown_fence "$file"
  [ "$status" -eq 0 ]
  [ "$(cat "$file")" = "$(printf 'line1\nline2')" ]
}

@test "strip_markdown_fence: 先頭のみフェンスの入力は変更しない" {
  local file="$BATS_TEST_TMPDIR/head_only.srt"
  printf '%s\n' '```' 'line1' 'line2' >"$file"

  run strip_markdown_fence "$file"
  [ "$status" -eq 0 ]
  [ "$(cat "$file")" = "$(printf '```\nline1\nline2')" ]
}

@test "strip_markdown_fence: 空ファイルはエラーにせず変更しない" {
  local file="$BATS_TEST_TMPDIR/empty.srt"
  touch "$file"

  run strip_markdown_fence "$file"
  [ "$status" -eq 0 ]
  [ ! -s "$file" ]
}

@test "parse_args: 既定値は ollama と gemma モデル" {
  parse_args "$BATS_TEST_TMPDIR/input.mov"
  [ "$AGENT" = "ollama" ]
  [ "$PROOFREAD_MODEL" = "gemma4:4b-it-qat" ]
  [ "$SUMMARIZE_MODEL" = "gemma4:12b-it-qat" ]
  [ "$INPUT_FILE" = "$BATS_TEST_TMPDIR/input.mov" ]
  [ "$VERBOSE" = "0" ]
}

@test "parse_args: --agent claude でモデル既定値が切り替わる" {
  parse_args --agent claude "$BATS_TEST_TMPDIR/input.mov"
  [ "$AGENT" = "claude" ]
  [ "$PROOFREAD_MODEL" = "haiku" ]
  [ "$SUMMARIZE_MODEL" = "sonnet" ]
}

@test "parse_args: モデルの明示指定は既定値より優先される" {
  parse_args --proofread-model custom-a --summarize-model custom-b "$BATS_TEST_TMPDIR/input.mov"
  [ "$PROOFREAD_MODEL" = "custom-a" ]
  [ "$SUMMARIZE_MODEL" = "custom-b" ]
}

@test "parse_args: 不正オプションで exit 1" {
  run parse_args --unknown "$BATS_TEST_TMPDIR/input.mov"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option: --unknown"* ]]
}

@test "parse_args: 不正な agent 値で exit 1" {
  run parse_args --agent gpt "$BATS_TEST_TMPDIR/input.mov"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid agent: gpt"* ]]
}

@test "parse_args: 入力ファイル欠落で exit 1" {
  run parse_args
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing required argument"* ]]
}
