#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../setup_launchd.sh"
}

@test "validate_schedule_value: 範囲内の整数を受け付ける" {
  run validate_schedule_value "AUDIO_SCRIBE_SCHEDULE_HOUR" "3" 23
  [ "$status" -eq 0 ]
}

@test "validate_schedule_value: 先頭ゼロ付きの整数を受け付ける" {
  run validate_schedule_value "AUDIO_SCRIBE_SCHEDULE_MINUTE" "09" 59
  [ "$status" -eq 0 ]
}

@test "validate_schedule_value: 上限は境界値を含む" {
  run validate_schedule_value "AUDIO_SCRIBE_SCHEDULE_HOUR" "23" 23
  [ "$status" -eq 0 ]
}

@test "validate_schedule_value: 範囲外はエラー" {
  run validate_schedule_value "AUDIO_SCRIBE_SCHEDULE_HOUR" "24" 23
  [ "$status" -ne 0 ]
}

@test "validate_schedule_value: 負数はエラー" {
  run validate_schedule_value "AUDIO_SCRIBE_SCHEDULE_HOUR" "-1" 23
  [ "$status" -ne 0 ]
}

@test "validate_schedule_value: 非整数はエラー" {
  run validate_schedule_value "AUDIO_SCRIBE_SCHEDULE_HOUR" "abc" 23
  [ "$status" -ne 0 ]
}

@test "render_plist: プレースホルダをすべて置換する" {
  run render_plist "/Users/me/Library/Application Support/audio-scribe/bin/audio-scribe-launcher" "3" "0" "/path/to/log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<string>/Users/me/Library/Application Support/audio-scribe/bin/audio-scribe-launcher</string>"* ]]
  [[ "$output" == *"<integer>3</integer>"* ]]
  [[ "$output" == *"<integer>0</integer>"* ]]
  [[ "$output" == *"<string>/path/to/log</string>"* ]]
  [[ "$output" != *"{{"* ]]
}

@test "render_plist: ProgramArguments はランチャー 1 個のみで mise や bash -c を含まない" {
  run render_plist "/path/to/launcher" "3" "0" "/path/to/log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<string>com.iimuz.audio-scribe</string>"* ]]
  [[ "$output" != *"mise"* ]]
  [[ "$output" != *"bash"* ]]
  [[ "$output" != *"run_audio_scribe_batch.sh"* ]]
}

@test "render_plist: WorkingDirectory を含まない" {
  run render_plist "/path/to/launcher" "3" "0" "/path/to/log"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WorkingDirectory"* ]]
}

@test "render_plist: 未置換のプレースホルダが残る場合はエラー" {
  cp "$BATS_TEST_DIRNAME/../setup_launchd.sh" "$BATS_TEST_TMPDIR/"
  printf '<string>{{UNKNOWN}}</string>\n' >"$BATS_TEST_TMPDIR/com.iimuz.audio-scribe.plist.template"
  run bash -c "source '$BATS_TEST_TMPDIR/setup_launchd.sh'; render_plist a 3 0 c"
  [ "$status" -ne 0 ]
}

@test "render_plist: パスの & < > を XML エスケープする" {
  run render_plist "/path/to/launcher & <test>" "3" "0" "/path/to/log & <test>"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<string>/path/to/launcher &amp; &lt;test&gt;</string>"* ]]
  [[ "$output" == *"<string>/path/to/log &amp; &lt;test&gt;</string>"* ]]
  [[ "$output" != *"{{"* ]]
}

@test "render_plist: patsub_replacement が無効でも XML エスケープが壊れない (bash 3.2 相当)" {
  run bash -c "shopt -u patsub_replacement 2>/dev/null; source '$BATS_TEST_DIRNAME/../setup_launchd.sh'; render_plist '/path/to/launcher & <test>' 3 0 '/path/to/log'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'<string>/path/to/launcher &amp; &lt;test&gt;</string>'* ]]
  [[ "$output" != *'\&amp;'* ]]
}

@test "render_wrapper: cd と mise exec を含み batch スクリプトを起動する" {
  run render_wrapper "/opt/homebrew/bin/mise" "/path/to/repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#!/bin/bash"* ]]
  [[ "$output" == *"cd /path/to/repo"* ]]
  [[ "$output" == *"exec /opt/homebrew/bin/mise exec -- bash -c"* ]]
  [[ "$output" == *"run_audio_scribe_batch.sh"* ]]
  [[ "$output" == *"AUDIO_SCRIBE_TARGET_DIR"* ]]
  [[ "$output" != *"{{"* ]]
}

@test "render_wrapper: AUDIO_SCRIBE_AGENT の実行時展開を含む" {
  run render_wrapper "/opt/homebrew/bin/mise" "/path/to/repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *'${AUDIO_SCRIBE_AGENT:+--agent "$AUDIO_SCRIBE_AGENT"}'* ]]
}

@test "render_wrapper: 空白や & を含むパスをシェル引用する" {
  run render_wrapper "/opt/home brew/mise" "/path/to/repo & test"
  [ "$status" -eq 0 ]
  [[ "$output" == *'cd /path/to/repo\ \&\ test'* ]]
  [[ "$output" == *'exec /opt/home\ brew/mise exec'* ]]
}

@test "render_wrapper: patsub_replacement が無効でも出力が壊れない (bash 3.2 相当)" {
  run bash -c "shopt -u patsub_replacement 2>/dev/null; source '$BATS_TEST_DIRNAME/../setup_launchd.sh'; render_wrapper '/opt/home brew/mise' '/path/to/repo & test'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'cd /path/to/repo\ \&\ test'* ]]
}

@test "render_wrapper: 未置換のプレースホルダが残る場合はエラー" {
  cp "$BATS_TEST_DIRNAME/../setup_launchd.sh" "$BATS_TEST_TMPDIR/"
  printf 'cd {{UNKNOWN}}\n' >"$BATS_TEST_TMPDIR/launchd_wrapper.sh.template"
  run bash -c "source '$BATS_TEST_TMPDIR/setup_launchd.sh'; render_wrapper a b"
  [ "$status" -ne 0 ]
}

@test "launcher_needs_build: ランチャーが無ければ真" {
  run launcher_needs_build "$BATS_TEST_TMPDIR/missing" "/path/to/run.sh"
  [ "$status" -eq 0 ]
}

@test "launcher_needs_build: 実行権限が無ければ真" {
  printf 'x\0/path/to/run.sh\0' >"$BATS_TEST_TMPDIR/launcher"
  chmod 644 "$BATS_TEST_TMPDIR/launcher"
  run launcher_needs_build "$BATS_TEST_TMPDIR/launcher" "/path/to/run.sh"
  [ "$status" -eq 0 ]
}

@test "launcher_needs_build: 埋め込みパスが一致すれば偽" {
  printf 'x\0/path/to/run.sh\0' >"$BATS_TEST_TMPDIR/launcher"
  chmod 755 "$BATS_TEST_TMPDIR/launcher"
  run launcher_needs_build "$BATS_TEST_TMPDIR/launcher" "/path/to/run.sh"
  [ "$status" -ne 0 ]
}

@test "launcher_needs_build: 埋め込みパスが異なれば真" {
  printf 'x\0/path/to/run.sh\0' >"$BATS_TEST_TMPDIR/launcher"
  chmod 755 "$BATS_TEST_TMPDIR/launcher"
  run launcher_needs_build "$BATS_TEST_TMPDIR/launcher" "/other/run.sh"
  [ "$status" -eq 0 ]
}
