#!/usr/bin/env bash
# Installs or uninstalls the launchd agent that runs
# run_audio_scribe_batch.sh on a daily schedule via a dedicated launcher
# binary and mise.
#
# Required tools: bash, launchctl, codesign, cc (Command Line Tools), mise
# Required siblings: com.iimuz.audio-scribe.plist.template,
#                    launchd_wrapper.sh.template, launcher.c

SCRIPT_NAME=$(basename "${0}")
readonly SCRIPT_NAME

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR

readonly LAUNCHD_LABEL="com.iimuz.audio-scribe"
readonly TEMPLATE_FILE="${SCRIPT_DIR}/${LAUNCHD_LABEL}.plist.template"
readonly PLIST_DEST="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
readonly LOG_PATH="${HOME}/Library/Logs/audio-scribe.log"
readonly WRAPPER_TEMPLATE_FILE="${SCRIPT_DIR}/launchd_wrapper.sh.template"
readonly LAUNCHER_SRC="${SCRIPT_DIR}/launcher.c"
# TCC (Full Disk Access) binds to the launcher's code identity, so it lives
# outside the repository and outside any package manager's reach.
readonly LAUNCHER_DIR="${HOME}/Library/Application Support/audio-scribe/bin"
readonly LAUNCHER_PATH="${LAUNCHER_DIR}/audio-scribe-launcher"
readonly WRAPPER_PATH="${LAUNCHER_DIR}/run.sh"
readonly LAUNCHER_IDENTIFIER="${LAUNCHD_LABEL}.launcher"

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
  install    Render the wrapper script and plist, build and ad-hoc sign the
             launcher binary if missing or stale, place the plist under
             ~/Library/LaunchAgents, and load it via launchctl bootstrap
             (idempotent). The launcher must be granted Full Disk Access
             once, by hand, in System Settings.
  uninstall  Unload the agent via launchctl bootout and remove the plist.
             The launcher and wrapper are kept so the Full Disk Access grant
             survives a reinstall.

OPTIONS:
  -h, --help     Show this help message
  -v, --verbose  Enable verbose output (set -x)

ENV:
  AUDIO_SCRIBE_TARGET_DIR      Directory processed at runtime (read from .env
                               by mise exec on each scheduled run)
  AUDIO_SCRIBE_AGENT           LLM agent: ollama or claude (read from .env by
                               mise exec on each scheduled run; default: ollama)
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

# Escapes &, < and > for safe embedding in plist XML text nodes. The
# replacement text embeds a literal "&", which under the patsub_replacement
# shell option (on by default since bash 5.2) must be backslash-escaped or
# bash treats it as "the text matched by pattern" (sed-style); older bash
# (including macOS system /bin/bash 3.2) has no such option and never
# treats "&" specially, so the escaped form there would leak a literal
# backslash into the output instead of protecting it.
function xml_escape() {
  local value="$1"
  if shopt -q patsub_replacement 2>/dev/null; then
    value="${value//&/\&amp;}"
    value="${value//</\&lt;}"
    value="${value//>/\&gt;}"
  else
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
  fi
  printf '%s' "$value"
}

# Escapes a string for safe use as the replacement text of
# ${content//pattern/replacement}: under patsub_replacement, bash treats an
# unescaped "&" there as "the text matched by pattern" (sed-style), so a
# literal "&" (e.g. from xml_escape's "&amp;") must be backslash-escaped,
# and literal backslashes escaped in turn, or it gets
# swallowed/misinterpreted during substitution. Older bash never treats "&"
# specially and has no such option, so escaping there would corrupt the
# output instead of protecting it.
function bash_repl_escape() {
  local value="$1"
  if shopt -q patsub_replacement 2>/dev/null; then
    value="${value//\\/\\\\}"
    value="${value//&/\\&}"
  fi
  printf '%s' "$value"
}

# Renders <template-file> to stdout, replacing each {{NAME}} with VALUE.
# Values must already be escaped for the target format by the caller.
# render_template <template-file> [NAME VALUE]...
function render_template() {
  local template_file="$1"
  shift
  local content
  content=$(<"$template_file")
  local name value
  while [[ $# -ge 2 ]]; do
    name="$1"
    value=$(bash_repl_escape "$2")
    content="${content//\{\{${name}\}\}/${value}}"
    shift 2
  done
  if [[ "$content" == *'{{'* ]]; then
    log_err "Unreplaced placeholder remains in rendered ${template_file##*/}"
    return 1
  fi
  printf '%s\n' "$content"
}

# render_plist <launcher-path> <hour> <minute> <log-path>
function render_plist() {
  render_template "$TEMPLATE_FILE" \
    LAUNCHER_PATH "$(xml_escape "$1")" \
    SCHEDULE_HOUR "$(xml_escape "$2")" \
    SCHEDULE_MINUTE "$(xml_escape "$3")" \
    LOG_PATH "$(xml_escape "$4")"
}

# render_wrapper <mise-bin> <repo-dir>
function render_wrapper() {
  render_template "$WRAPPER_TEMPLATE_FILE" \
    MISE_BIN "$(printf '%q' "$1")" \
    REPO_DIR "$(printf '%q' "$2")"
}

# Returns 0 when the launcher must be (re)built: it is missing, or the
# embedded wrapper path differs from <wrapper-path>. Source mtime is
# deliberately ignored: a rebuild changes the code identity and revokes the
# Full Disk Access grant, so it must only happen when unavoidable.
# launcher_needs_build <launcher-path> <wrapper-path>
function launcher_needs_build() {
  local launcher_path="$1" wrapper_path="$2"
  [[ -x "$launcher_path" ]] || return 0
  if grep -aqF -- "$wrapper_path" "$launcher_path"; then
    return 1
  fi
  return 0
}

# Compiles launcher.c with <wrapper-path> baked in and ad-hoc signs it.
# build_launcher <launcher-path> <wrapper-path>
function build_launcher() {
  local launcher_path="$1" wrapper_path="$2"
  if ! xcode-select -p >/dev/null 2>&1; then
    log_err "Command Line Tools not found. Install with: xcode-select --install"
    return 1
  fi
  local tmp="${launcher_path}.tmp.$$"
  log_info "Building launcher: ${launcher_path}"
  if ! /usr/bin/cc -O2 -DSCRIPT_PATH="\"${wrapper_path}\"" -o "$tmp" "$LAUNCHER_SRC"; then
    rm -f "$tmp"
    log_err "Failed to compile launcher"
    return 1
  fi
  if ! codesign --force --sign - --identifier "$LAUNCHER_IDENTIFIER" "$tmp"; then
    rm -f "$tmp"
    log_err "Failed to sign launcher"
    return 1
  fi
  if ! mv "$tmp" "$launcher_path"; then
    rm -f "$tmp"
    log_err "Failed to install launcher binary"
    return 1
  fi
  log_err "WARNING: launcher was (re)built; grant Full Disk Access to it again: ${launcher_path}"
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
  local required
  for required in "$TEMPLATE_FILE" "$WRAPPER_TEMPLATE_FILE" "$LAUNCHER_SRC"; do
    if [[ ! -r "$required" ]]; then
      log_err "Required file not found or not readable: ${required}"
      exit 1
    fi
  done

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
    log_err "WARNING: AUDIO_SCRIBE_TARGET_DIR is not set. Set it in .env before the first scheduled run."
  fi

  mkdir -p "$(dirname "$PLIST_DEST")" "$(dirname "$LOG_PATH")" "$LAUNCHER_DIR"
  : >>"$LOG_PATH"

  local tmp_wrapper="${WRAPPER_PATH}.tmp.$$"
  if ! render_wrapper "$mise_bin" "$SCRIPT_DIR" >"$tmp_wrapper"; then
    rm -f "$tmp_wrapper"
    log_err "Failed to render wrapper script"
    exit 1
  fi
  chmod 755 "$tmp_wrapper"
  mv "$tmp_wrapper" "$WRAPPER_PATH"

  if launcher_needs_build "$LAUNCHER_PATH" "$WRAPPER_PATH"; then
    build_launcher "$LAUNCHER_PATH" "$WRAPPER_PATH" || exit 1
  else
    log_info "Launcher up to date: ${LAUNCHER_PATH}"
  fi

  local rendered
  rendered=$(render_plist "$LAUNCHER_PATH" "$hour" "$minute" "$LOG_PATH")

  local tmp_plist="${PLIST_DEST}.tmp.$$"
  printf '%s\n' "$rendered" >"$tmp_plist"
  if command -v plutil >/dev/null 2>&1; then
    if ! plutil -lint "$tmp_plist" >/dev/null; then
      rm -f "$tmp_plist"
      log_err "Rendered plist failed validation"
      exit 1
    fi
  fi
  mv "$tmp_plist" "$PLIST_DEST"

  # Reload if already loaded so that reinstall is idempotent.
  launchctl bootout "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"

  log_info "Installed launchd agent: ${LAUNCHD_LABEL}"
  log_info "Schedule: daily at $(printf '%02d' "$((10#$hour))"):$(printf '%02d' "$((10#$minute))")"
  log_info "Log file: ${LOG_PATH}"
  log_info "Launcher: ${LAUNCHER_PATH}"
  log_info "First install or rebuilt launcher: add the launcher to System Settings > Privacy & Security > Full Disk Access (press Cmd+Shift+G in the file dialog and enter: ${LAUNCHER_DIR})"
  log_info "Then verify with: launchctl kickstart -k gui/$(id -u)/${LAUNCHD_LABEL} && mise run launchd:logs"
}

function cmd_uninstall() {
  launchctl bootout "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null || true
  rm -f "$PLIST_DEST"
  log_info "Uninstalled launchd agent: ${LAUNCHD_LABEL}"
  log_info "Launcher and wrapper are kept so the Full Disk Access grant survives a reinstall. Remove by hand if no longer needed: ${LAUNCHER_DIR}"
}

function main() {
  parse_args "$@"

  if [[ "$VERBOSE" -eq 1 ]]; then
    set -x
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
