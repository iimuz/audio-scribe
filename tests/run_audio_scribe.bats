#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../run_audio_scribe.sh"
}

stub_uv() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/uv" <<'EOF'
#!/usr/bin/env bash
# Invoked as: uv run --project <dir> <script> <input_wav> <interim_dir>
input_wav="$5"
interim_dir="$6"
mkdir -p "$interim_dir"
if [[ -n "${HF_TOKEN+x}" ]]; then
  printf 'set:%s\n' "$HF_TOKEN" >"$interim_dir/hf_token_seen"
else
  printf 'unset\n' >"$interim_dir/hf_token_seen"
fi
echo "1" >"$interim_dir/$(basename "$input_wav" .wav).srt"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/uv"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
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

@test "transcribe: HF_TOKEN 未設定なら WARN を出し、dummy を渡さない" {
  stub_uv
  unset HF_TOKEN
  local interim="$BATS_TEST_TMPDIR/interim"
  local checkpoint="$BATS_TEST_TMPDIR/meeting-asr.srt"

  run transcribe "$BATS_TEST_TMPDIR/meeting.wav" "$interim" "$checkpoint"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] HF_TOKEN is not set"* ]]
  [ "$(grep -c '\[WARN\]' <<<"$output")" -eq 1 ]
  [[ "$output" != *"[ERROR]"* ]]
  [ "$(cat "$interim/hf_token_seen")" = "unset" ]
  [ -s "$checkpoint" ]
}

@test "transcribe: HF_TOKEN が空なら WARN を出し、空のまま渡す" {
  stub_uv
  export HF_TOKEN=""
  local interim="$BATS_TEST_TMPDIR/interim"

  run transcribe "$BATS_TEST_TMPDIR/meeting.wav" "$interim" "$BATS_TEST_TMPDIR/meeting-asr.srt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] HF_TOKEN is not set"* ]]
  [ "$(cat "$interim/hf_token_seen")" = "set:" ]
}

@test "transcribe: HF_TOKEN 設定時は警告せずそのまま渡す" {
  stub_uv
  export HF_TOKEN="hf_test"
  local interim="$BATS_TEST_TMPDIR/interim"

  run transcribe "$BATS_TEST_TMPDIR/meeting.wav" "$interim" "$BATS_TEST_TMPDIR/meeting-asr.srt"
  [ "$status" -eq 0 ]
  [[ "$output" != *"[WARN]"* ]]
  [ "$(cat "$interim/hf_token_seen")" = "set:hf_test" ]
}

@test "transcribe: set -u でも HF_TOKEN 未設定で落ちない" {
  stub_uv
  unset HF_TOKEN
  local interim="$BATS_TEST_TMPDIR/interim"

  run bash -u -c 'source "$1" && transcribe "$2" "$3" "$4"' _ \
    "$BATS_TEST_DIRNAME/../run_audio_scribe.sh" \
    "$BATS_TEST_TMPDIR/meeting.wav" "$interim" "$BATS_TEST_TMPDIR/meeting-asr.srt"
  [ "$status" -eq 0 ]
  [ "$(cat "$interim/hf_token_seen")" = "unset" ]
}
