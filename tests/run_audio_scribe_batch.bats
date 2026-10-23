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

teardown() {
  # Restore permissions removed by the scan-failure test so bats can clean up.
  chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# Copies the batch script next to a fake run_audio_scribe.sh that appends its
# last argument (the input file) to processed.txt and succeeds.
setup_batch_fixture() {
  BIN_DIR="$BATS_TEST_TMPDIR/bin"
  PROCESSED="$BIN_DIR/processed.txt"
  mkdir -p "$BIN_DIR"
  cp "$BATS_TEST_DIRNAME/../run_audio_scribe_batch.sh" "$BIN_DIR/"
  cat >"$BIN_DIR/run_audio_scribe.sh" <<'EOF'
printf '%s\n' "${!#}" >>"$(dirname "$0")/processed.txt"
EOF
}

@test "main: 複数のディレクトリを引数の順に、各ディレクトリの中は並べた順に処理する" {
  setup_batch_fixture
  local a="$BATS_TEST_TMPDIR/rec/a" b="$BATS_TEST_TMPDIR/rec/b"
  mkdir -p "$a" "$b/sub"
  touch "$a/a1.mov" "$b/b1.mov" "$b/sub/b2.mov"

  run bash "$BIN_DIR/run_audio_scribe_batch.sh" "$b" "$a"
  [ "$status" -eq 0 ]
  [ "$(cat "$PROCESSED")" = "$(printf '%s\n' "$b/b1.mov" "$b/sub/b2.mov" "$a/a1.mov")" ]
  [[ "$output" == *"[3/3] Processing: $a/a1.mov"* ]]
  [[ "$output" == *"Summary: total=3 succeeded=3 failed=0"* ]]
}

@test "main: 1 つのディレクトリを渡す呼び出しは今までどおり処理する" {
  setup_batch_fixture
  local a="$BATS_TEST_TMPDIR/rec/a"
  mkdir -p "$a"
  touch "$a/x.mov" "$a/y.MOV"

  run bash "$BIN_DIR/run_audio_scribe_batch.sh" "$a"
  [ "$status" -eq 0 ]
  [ "$(cat "$PROCESSED")" = "$(printf '%s\n' "$a/x.mov" "$a/y.MOV")" ]
}

@test "main: 存在しないディレクトリを警告して飛ばし、残りを処理して 0 で終わる" {
  setup_batch_fixture
  local a="$BATS_TEST_TMPDIR/rec/a" missing="$BATS_TEST_TMPDIR/rec/missing"
  mkdir -p "$a"
  touch "$a/a1.mov"

  run bash "$BIN_DIR/run_audio_scribe_batch.sh" "$missing" "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] Not a directory, skipping: $missing"* ]]
  [ "$(cat "$PROCESSED")" = "$a/a1.mov" ]
}

@test "main: 指定したものがすべてディレクトリでなければ何も処理せず 1 で終わる" {
  setup_batch_fixture
  local file="$BATS_TEST_TMPDIR/rec/file.mov"
  mkdir -p "$BATS_TEST_TMPDIR/rec"
  touch "$file"

  run bash "$BIN_DIR/run_audio_scribe_batch.sh" "$BATS_TEST_TMPDIR/rec/missing" "$file"
  [ "$status" -eq 1 ]
  [[ "$output" == *"None of the given paths is a directory"* ]]
  [ ! -e "$PROCESSED" ]
}

@test "main: 空文字列の引数は警告して飛ばす" {
  setup_batch_fixture
  local a="$BATS_TEST_TMPDIR/rec/a"
  mkdir -p "$a"
  touch "$a/a1.mov"

  run bash "$BIN_DIR/run_audio_scribe_batch.sh" "" "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] Not a directory, skipping: "* ]]
  [ "$(cat "$PROCESSED")" = "$a/a1.mov" ]
}

@test "main: 位置引数が無ければ 1 で終わる" {
  setup_batch_fixture

  run bash "$BIN_DIR/run_audio_scribe_batch.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing required argument: <directory>"* ]]
}

@test "main: オプションはディレクトリの間にも書ける" {
  setup_batch_fixture
  local a="$BATS_TEST_TMPDIR/rec/a" b="$BATS_TEST_TMPDIR/rec/b"
  mkdir -p "$a" "$b"
  touch "$a/a1.mov" "$b/b1.mov"

  run bash "$BIN_DIR/run_audio_scribe_batch.sh" "$a" --agent claude "$b"
  [ "$status" -eq 0 ]
  [ "$(cat "$PROCESSED")" = "$(printf '%s\n' "$a/a1.mov" "$b/b1.mov")" ]
}

@test "main: どのディレクトリにも .mov が無ければ 0 で終わる" {
  setup_batch_fixture
  local a="$BATS_TEST_TMPDIR/rec/a" b="$BATS_TEST_TMPDIR/rec/b"
  mkdir -p "$a" "$b"

  run bash "$BIN_DIR/run_audio_scribe_batch.sh" "$a" "$b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No .mov files found under the target directories"* ]]
  [ ! -e "$PROCESSED" ]
}

@test "main: 走査に失敗したディレクトリがあればどの録画も処理せず 1 で終わる" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "permission checks do not apply to root"
  fi
  setup_batch_fixture
  local a="$BATS_TEST_TMPDIR/rec/a" b="$BATS_TEST_TMPDIR/rec/b"
  mkdir -p "$a" "$b/locked"
  touch "$a/a1.mov"
  chmod 000 "$b/locked"

  run bash "$BIN_DIR/run_audio_scribe_batch.sh" "$a" "$b"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to scan directory: $b"* ]]
  [ ! -e "$PROCESSED" ]
}
