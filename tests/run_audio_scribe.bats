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
