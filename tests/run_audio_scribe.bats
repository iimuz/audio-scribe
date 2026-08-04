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
