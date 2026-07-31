#!/usr/bin/env bash
# Batch wrapper for run_audio_scribe.sh.
# Recursively finds .mov files under a given directory and processes each
# one sequentially by calling the sibling run_audio_scribe.sh.
#
# Required tools: bash, find, sort
# Required sibling: run_audio_scribe.sh (must be in the same directory)

set -Eeuo pipefail

SCRIPT_NAME=$(basename "${0}")
readonly SCRIPT_NAME

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR

readonly CHILD_SCRIPT="${SCRIPT_DIR}/run_audio_scribe.sh"

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

trap 'err ${LINENO} "$BASH_COMMAND"' ERR

function usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] <directory>

Recursively finds .mov files under <directory> and runs run_audio_scribe.sh
on each one sequentially. Continues processing remaining files even if one fails.

OPTIONS:
  -h, --help         Show this help message
  -v, --verbose      Enable verbose output (set -x)
  -a, --agent AGENT  LLM agent: ollama or claude (passed through to run_audio_scribe.sh)
  --proofread-model MODEL   Model for proofreading (passed through to run_audio_scribe.sh)
  --summarize-model MODEL   Model for summarization (passed through to run_audio_scribe.sh)

ENV:
  HF_TOKEN   HuggingFace token (passed through to run_audio_scribe.sh)
  API_URL    ollama API endpoint (passed through to run_audio_scribe.sh)
  NUM_CTX    ollama context window in tokens (passed through to run_audio_scribe.sh)

EXAMPLES:
  ${SCRIPT_NAME} /path/to/recordings
  ${SCRIPT_NAME} --verbose ./meetings
  ${SCRIPT_NAME} --agent claude --summarize-model haiku ./meetings
EOF
}

function main() {
  local verbose=0
  local target_dir=""
  local agent="" proofread_model="" summarize_model=""

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
    -a | --agent)
      if [[ $# -lt 2 ]]; then
        log_err "Missing value for $1"
        usage >&2
        exit 1
      fi
      agent="$2"
      shift 2
      ;;
    --proofread-model)
      if [[ $# -lt 2 ]]; then
        log_err "Missing value for $1"
        usage >&2
        exit 1
      fi
      proofread_model="$2"
      shift 2
      ;;
    --summarize-model)
      if [[ $# -lt 2 ]]; then
        log_err "Missing value for $1"
        usage >&2
        exit 1
      fi
      summarize_model="$2"
      shift 2
      ;;
    -*)
      log_err "Unknown option: $1"
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$target_dir" ]]; then
        log_err "Too many positional arguments"
        usage >&2
        exit 1
      fi
      target_dir="$1"
      shift
      ;;
    esac
  done

  if [[ -z "$target_dir" ]]; then
    log_err "Missing required argument: <directory>"
    usage >&2
    exit 1
  fi

  if [[ ! -r "$CHILD_SCRIPT" ]]; then
    log_err "Child script not found or not readable: ${CHILD_SCRIPT}"
    exit 1
  fi

  if [[ ! -d "$target_dir" ]]; then
    log_err "Target directory not found or not a directory: ${target_dir}"
    exit 1
  fi

  if [[ "$verbose" -eq 1 ]]; then
    set -x
  fi

  # Collect .mov files (NUL-delimited, sorted deterministically)
  local files=()
  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(find "$target_dir" -type f -iname '*.mov' -print0 | sort -z)

  local total="${#files[@]}"

  if [[ "$total" -eq 0 ]]; then
    log_info "No .mov files found under ${target_dir}"
    exit 0
  fi

  log_info "Found ${total} .mov file(s) under ${target_dir}"

  local child_args=()
  [[ -n "$agent" ]] && child_args+=(--agent "$agent")
  [[ -n "$proofread_model" ]] && child_args+=(--proofread-model "$proofread_model")
  [[ -n "$summarize_model" ]] && child_args+=(--summarize-model "$summarize_model")

  local succeeded=0
  local failed_files=()

  local i=0
  for file in "${files[@]}"; do
    i=$((i + 1))
    log_info "[${i}/${total}] Processing: ${file}"
    if bash "$CHILD_SCRIPT" "${child_args[@]}" "$file"; then
      succeeded=$((succeeded + 1))
      log_info "[${i}/${total}] Succeeded: ${file}"
    else
      log_err "[${i}/${total}] Failed: ${file}"
      failed_files+=("$file")
    fi
  done

  local failed_count="${#failed_files[@]}"
  log_info "Summary: total=${total} succeeded=${succeeded} failed=${failed_count}"

  if [[ "$failed_count" -gt 0 ]]; then
    log_err "The following files failed:"
    for f in "${failed_files[@]}"; do
      log_err "  ${f}"
    done
    exit 1
  fi

  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
