#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../run_audio_scribe_batch.sh"
}

@test "collect_mov_files: .mov を再帰的に NUL 区切りで列挙する" {
  local dir="$BATS_TEST_TMPDIR/target"
  mkdir -p "$dir/sub"
  touch "$dir/a.MOV" "$dir/b.mov" "$dir/sub/c.mov" "$dir/d.txt"
  local out="$BATS_TEST_TMPDIR/list"

  run collect_mov_files "$dir" "$out"
  [ "$status" -eq 0 ]
  [ "$(tr '\0' '\n' <"$out")" = "$(printf '%s\n%s\n%s\n' "$dir/a.MOV" "$dir/b.mov" "$dir/sub/c.mov")" ]
}

@test "collect_mov_files: .mov がない場合は空の出力で成功する" {
  local dir="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$dir"
  local out="$BATS_TEST_TMPDIR/list"

  run collect_mov_files "$dir" "$out"
  [ "$status" -eq 0 ]
  [ ! -s "$out" ]
}

@test "collect_mov_files: 走査に失敗した場合は非 0 を返す" {
  local out="$BATS_TEST_TMPDIR/list"

  run collect_mov_files "$BATS_TEST_TMPDIR/missing" "$out"
  [ "$status" -ne 0 ]
}
