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

# Parses CLI arguments. Sets readonly globals: COMMAND, VERBOSE
function parse_args() {
  local verbose=0
  local command=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      -h | --help)
        usage
        exit 0
        ;;
      -v | --verbose)
        verbose=1
        shift
        ;;
      -*)
        log_err "Unknown option: $1"
        usage >&2
        exit 1
        ;;
      *)
        if [[ -n "$command" ]]; then
          log_err "Too many positional arguments"
          usage >&2
          exit 1
        fi
        command="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$command" ]]; then
    log_err "Missing required argument: <install|uninstall>"
    usage >&2
    exit 1
  fi

  if [[ "$command" != "install" && "$command" != "uninstall" ]]; then
    log_err "Unknown command: ${command}"
    usage >&2
    exit 1
  fi

  COMMAND="$command"
  VERBOSE="$verbose"
  readonly COMMAND VERBOSE
}

function cmd_install() {
  local mise_bin
  if ! mise_bin=$(command -v mise); then
    log_err "mise not found in PATH"
    exit 1
  fi

  local hour="${AUDIO_SCRIBE_SCHEDULE_HOUR:-3}"
  local minute="${AUDIO_SCRIBE_SCHEDULE_MINUTE:-0}"
  validate_schedule_value "AUDIO_SCRIBE_SCHEDULE_HOUR" "$hour" 23 || exit 1
  validate_schedule_value "AUDIO_SCRIBE_SCHEDULE_MINUTE" "$minute" 59 || exit 1

  if [[ -z "${AUDIO_SCRIBE_TARGET_DIR:-}" ]]; then
    log_info "WARNING: AUDIO_SCRIBE_TARGET_DIR is not set. Set it in .env before the first scheduled run."
  fi

  mkdir -p "$(dirname "$PLIST_DEST")" "$(dirname "$LOG_PATH")"

  local rendered
  rendered=$(render_plist "$mise_bin" "$SCRIPT_DIR" "$hour" "$minute" "$LOG_PATH")
  printf '%s\n' "$rendered" >"$PLIST_DEST"

  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$PLIST_DEST" >/dev/null
  fi

  # Reload if already loaded so that reinstall is idempotent.
  launchctl bootout "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"

  log_info "Installed launchd agent: ${LAUNCHD_LABEL}"
  log_info "Schedule: daily at ${hour}:$(printf '%02d' "$((10#$minute))")"
  log_info "Log file: ${LOG_PATH}"
}

function cmd_uninstall() {
  launchctl bootout "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || true
  rm -f "$PLIST_DEST"
  log_info "Uninstalled launchd agent: ${LAUNCHD_LABEL}"
}

function main() {
  parse_args "$@"

  if [[ "$VERBOSE" -eq 1 ]]; then
    set -x
  fi

  if [[ ! -r "$TEMPLATE_FILE" ]]; then
    log_err "Template not found or not readable: ${TEMPLATE_FILE}"
    exit 1
  fi

  case "$COMMAND" in
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -Eeuo pipefail
  trap 'err ${LINENO} "$BASH_COMMAND"' ERR
  main "$@"
fi
