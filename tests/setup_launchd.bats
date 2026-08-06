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
  run render_plist "/opt/homebrew/bin/mise" "/path/to/repo" "3" "0" "/path/to/log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<string>/opt/homebrew/bin/mise</string>"* ]]
  [[ "$output" == *"<string>/path/to/repo</string>"* ]]
  [[ "$output" == *"<integer>3</integer>"* ]]
  [[ "$output" == *"<integer>0</integer>"* ]]
  [[ "$output" == *"<string>/path/to/log</string>"* ]]
  [[ "$output" != *"{{"* ]]
}

@test "render_plist: ラベルと batch スクリプト呼び出しを含む" {
  run render_plist "/opt/homebrew/bin/mise" "/path/to/repo" "3" "0" "/path/to/log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<string>com.iimuz.audio-scribe</string>"* ]]
  [[ "$output" == *"run_audio_scribe_batch.sh"* ]]
  [[ "$output" == *"AUDIO_SCRIBE_TARGET_DIR"* ]]
}

@test "render_plist: 未置換のプレースホルダが残る場合はエラー" {
  cp "$BATS_TEST_DIRNAME/../setup_launchd.sh" "$BATS_TEST_TMPDIR/"
  printf '<string>{{UNKNOWN}}</string>\n' >"$BATS_TEST_TMPDIR/com.iimuz.audio-scribe.plist.template"
  run bash -c "source '$BATS_TEST_TMPDIR/setup_launchd.sh'; render_plist a b 3 0 c"
  [ "$status" -ne 0 ]
}

@test "render_plist: リポジトリパスの & < > を XML エスケープする" {
  run render_plist "/opt/homebrew/bin/mise" "/path/to/repo & <test>" "3" "0" "/path/to/log & <test>"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<string>/path/to/repo &amp; &lt;test&gt;</string>"* ]]
  [[ "$output" == *"<string>/path/to/log &amp; &lt;test&gt;</string>"* ]]
  [[ "$output" != *"{{"* ]]
}
