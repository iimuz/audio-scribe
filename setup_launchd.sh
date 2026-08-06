#!/usr/bin/env bash
# Installs or uninstalls the launchd agent that runs
# run_audio_scribe_batch.sh on a daily schedule via mise.
#
# Required tools: bash, launchctl (macOS), mise
# Required sibling: com.iimuz.audio-scribe.plist.template

SCRIPT_NAME=$(basename "${0}")
readonly SCRIPT_NAME

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR

readonly LAUNCHD_LABEL="com.iimuz.audio-scribe"
export LAUNCHD_LABEL
readonly TEMPLATE_FILE="${SCRIPT_DIR}/${LAUNCHD_LABEL}.plist.template"
export TEMPLATE_FILE
readonly PLIST_DEST="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
export PLIST_DEST
readonly LOG_PATH="${HOME}/Library/Logs/audio-scribe.log"
export LOG_PATH

function log_info() {
  local message="$1"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$SCRIPT_NAME] [INFO] $message" >&2
}

function log_err() {
  local message="$1"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$SCRIPT_NAME] [ERROR] $message" >&2
}

function err() {
  log_err "Line $1: $2"
  exit 1
}

function usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] <install|uninstall>

Installs or uninstalls the launchd agent (${LAUNCHD_LABEL}) that runs
run_audio_scribe_batch.sh on a daily schedule.

COMMANDS:
  install    Render the plist template, place it under ~/Library/LaunchAgents,
             and load it via launchctl bootstrap (idempotent).
  uninstall  Unload the agent via launchctl bootout and remove the plist.

OPTIONS:
  -h, --help     Show this help message
  -v, --verbose  Enable verbose output (set -x)

ENV:
  AUDIO_SCRIBE_TARGET_DIR      Directory processed at runtime (read from .env
                               by mise exec on each scheduled run)
  AUDIO_SCRIBE_SCHEDULE_HOUR   Hour of the daily run, 0-23 (default: 3;
                               embedded into the plist at install time)
  AUDIO_SCRIBE_SCHEDULE_MINUTE Minute of the daily run, 0-59 (default: 0;
                               embedded into the plist at install time)

EXAMPLES:
  mise run launchd:install
  mise run launchd:uninstall
EOF
}

# Validates that a schedule value is an integer within [0, max].
# validate_schedule_value <name> <value> <max>
function validate_schedule_value() {
  local name="$1" value="$2" max="$3"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    log_err "${name} must be a non-negative integer: ${value}"
    return 1
  fi
  if ((10#$value > max)); then
    log_err "${name} must be in range 0-${max}: ${value}"
    return 1
  fi
}

# Renders TEMPLATE_FILE to stdout, replacing {{...}} placeholders.
# render_plist <mise-bin> <repo-dir> <hour> <minute> <log-path>
function render_plist() {
  local mise_bin="$1" repo_dir="$2" hour="$3" minute="$4" log_path="$5"
  local content
  content=$(<"$TEMPLATE_FILE")
  content="${content//\{\{MISE_BIN\}\}/${mise_bin}}"
  content="${content//\{\{REPO_DIR\}\}/${repo_dir}}"
  content="${content//\{\{SCHEDULE_HOUR\}\}/${hour}}"
  content="${content//\{\{SCHEDULE_MINUTE\}\}/${minute}}"
  content="${content//\{\{LOG_PATH\}\}/${log_path}}"
  if [[ "$content" == *'{{'* ]]; then
    log_err "Unreplaced placeholder remains in rendered plist"
    return 1
  fi
  printf '%s\n' "$content"
}

function main() {
  log_err "Not implemented yet"
  exit 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -Eeuo pipefail
  trap 'err ${LINENO} "$BASH_COMMAND"' ERR
  main "$@"
fi
