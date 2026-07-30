#!/usr/bin/env bash
# Audio transcription and summarization pipeline.
#
# Required tools: bash, ffmpeg, uv (whisperx), jq, curl, ollama
#
# ENV:
#   HF_TOKEN   HuggingFace token for speaker diarization.
#              If unset or empty, falls back to "dummy" with a warning.
#   MODEL      ollama model (default: gemma4:12b-it-qat)
#   API_URL    ollama API endpoint (default: http://localhost:11434/api/generate)
#   NUM_CTX    ollama context window in tokens (default: 16384)

set -Eeuo pipefail

SCRIPT_NAME=$(basename "${0}")
readonly SCRIPT_NAME

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR

# Global constants (overridable via env)
: "${MODEL:=gemma4:12b-it-qat}"
readonly MODEL
: "${API_URL:=http://localhost:11434/api/generate}"
readonly API_URL
# Proofread regenerates the full transcript, so the context window must hold
# prompt + input SRT + output SRT. Too small a value yields an empty response.
# 16 K = 16384
# 128 K = 131072
# 256 K = 262144
: "${NUM_CTX:=131072}"
readonly NUM_CTX

readonly INTERIM_DIR="./data/interim"

# Temp file registry for EXIT trap
TMP_FILES=()

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
trap 'cleanup_tmp' EXIT

function cleanup_tmp() {
  if [[ ${#TMP_FILES[@]} -gt 0 ]]; then
    rm -f "${TMP_FILES[@]}"
  fi
}

function register_tmp() {
  TMP_FILES+=("$1")
}

function usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] <video-or-audio-file>

Transcribes a meeting video/audio file and generates a summary.

OPTIONS:
  -h, --help     Show this help message
  -v, --verbose  Enable verbose output (set -x)

ENV:
  HF_TOKEN   HuggingFace token (required for diarization; falls back to dummy)
  MODEL      ollama model (default: gemma4:12b-it-qat)
  API_URL    ollama API (default: http://localhost:11434/api/generate)
  NUM_CTX    ollama context window in tokens (default: 16384)

EXAMPLES:
  ${SCRIPT_NAME} meeting.mov
  ${SCRIPT_NAME} --verbose /path/to/recording.mp4
EOF
}

# extract_audio <input_video> <output_wav>
function extract_audio() {
  [[ $# -eq 2 ]] || err "${LINENO}" "extract_audio requires 2 args"
  local input_video="$1" output_wav="$2"
  log_info "Extracting audio: ${input_video} -> ${output_wav}"
  ffmpeg -i "$input_video" -vn -acodec pcm_s16le -ar 16000 -ac 1 "$output_wav"
}

# transcribe <input_wav> <interim_dir> <checkpoint_srt>
function transcribe() {
  [[ $# -eq 3 ]] || err "${LINENO}" "transcribe requires 3 args"
  local input_wav="$1" interim_dir="$2" checkpoint_srt="$3"

  local hf_token
  if [[ -z "${HF_TOKEN:-}" ]]; then
    log_err "HF_TOKEN is not set; falling back to dummy. Diarization may fail."
    hf_token="dummy"
  else
    hf_token="$HF_TOKEN"
  fi
  readonly hf_token

  log_info "Running whisperx: ${input_wav}"
  uv run whisperx "$input_wav" \
    --output_dir "$interim_dir" \
    --model large-v3-turbo \
    --diarize \
    --output_format srt \
    --device cpu \
    --batch_size 4 \
    --language ja \
    --compute_type int8 \
    --hf_token="$hf_token"

  local base
  base=$(basename "$input_wav" .wav)
  readonly base

  local whisperx_srt="${interim_dir}/${base}.srt"
  log_info "Copying ASR result to checkpoint: ${checkpoint_srt}"
  cp "$whisperx_srt" "$checkpoint_srt"
}

# run_ollama <prompt_template_file> <input_file> <output_file>
function run_ollama() {
  [[ $# -eq 3 ]] || err "${LINENO}" "run_ollama requires 3 args"
  local template_file="$1" input_file="$2" output_file="$3"

  local prompt_file request_file response_file
  prompt_file=$(mktemp)
  register_tmp "$prompt_file"
  request_file=$(mktemp)
  register_tmp "$request_file"
  response_file=$(mktemp)
  register_tmp "$response_file"
  readonly prompt_file request_file response_file

  # Step 1: build prompt by replacing {{INPUT}} with file contents
  jq -Rs --rawfile template "$template_file" \
    '. as $input | $template | split("{{INPUT}}") | join($input)' \
    "$input_file" >"$prompt_file"

  # Step 2: build request JSON (streaming enabled for live output)
  jq -n --arg model "$MODEL" --argjson num_ctx "$NUM_CTX" --rawfile prompt "$prompt_file" \
    '{ model: $model, stream: true, options: { temperature: 0, num_ctx: $num_ctx }, prompt: $prompt }' \
    >"$request_file"

  # Step 3: call ollama API and stream the response.
  # The raw JSON-Lines stream is saved to response_file for validation, while
  # the generated tokens are extracted live: shown on stderr and accumulated
  # into output_file. --no-buffer / --unbuffered keep the output flowing.
  curl -sS --no-buffer "$API_URL" -H "Content-Type: application/json" \
    --data-binary @"$request_file" |
    tee "$response_file" |
    jq -j --unbuffered '.response // empty' |
    tee "$output_file" >&2
  echo >&2

  # Step 4: validate the result.
  # An API error arrives as an object with an .error field somewhere in the
  # stream; an empty output_file means no tokens were produced at all.
  if jq -se 'any(.[]; has("error"))' "$response_file" >/dev/null 2>&1; then
    err "${LINENO}" "ollama returned an error: $(jq -rs '[.[] | .error // empty] | join("; ")' "$response_file")"
  fi
  if [[ ! -s "$output_file" ]]; then
    err "${LINENO}" "ollama returned an empty response (model=${MODEL}, num_ctx=${NUM_CTX}). Check ollama logs / increase NUM_CTX."
  fi
  # jq -j does not append a trailing newline; add one for consistency.
  echo >>"$output_file"
}

function main() {
  local verbose=0
  local input_file=""

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
      if [[ -n "$input_file" ]]; then
        log_err "Too many positional arguments"
        usage >&2
        exit 1
      fi
      input_file="$1"
      shift
      ;;
    esac
  done

  if [[ -z "$input_file" ]]; then
    log_err "Missing required argument: <video-or-audio-file>"
    usage >&2
    exit 1
  fi

  if [[ ! -f "$input_file" || ! -r "$input_file" ]]; then
    log_err "File not found or not readable: ${input_file}"
    exit 1
  fi

  if [[ "$verbose" -eq 1 ]]; then
    set -x
  fi

  local base video_dir
  base=$(basename "$input_file")
  base="${base%.*}"
  video_dir=$(cd "$(dirname "$input_file")" && pwd)
  readonly base video_dir

  # Derived paths
  local cp_summary="${video_dir}/${base}-summary.md"
  local cp_asr="${video_dir}/${base}-asr.srt"
  local cp_proofread="${video_dir}/${base}-proofread.srt"
  readonly cp_summary cp_asr cp_proofread

  local interim_wav="${INTERIM_DIR}/${base}.wav"
  local interim_asr="${INTERIM_DIR}/${base}.srt"
  local interim_proofread="${INTERIM_DIR}/${base}-proofread.srt"
  local interim_summary="${INTERIM_DIR}/${base}-summary.md"
  readonly interim_wav interim_asr interim_proofread interim_summary

  local proofread_prompt="${SCRIPT_DIR}/prompts/proofread.md"
  local summarize_prompt="${SCRIPT_DIR}/prompts/summarize.md"
  readonly proofread_prompt summarize_prompt

  # Requirement 8: final result already exists, nothing to do
  if [[ -s "$cp_summary" ]]; then
    log_info "Final result already exists: ${cp_summary}. Nothing to do."
    exit 0
  fi

  mkdir -p "$INTERIM_DIR"

  # Stage: whisperx (ASR)
  if [[ -s "$cp_asr" ]]; then
    log_info "ASR checkpoint found, skipping whisperx: ${cp_asr}"
    cp "$cp_asr" "$interim_asr"
  else
    extract_audio "$input_file" "$interim_wav"
    transcribe "$interim_wav" "$INTERIM_DIR" "$cp_asr"
    # interim_asr is the whisperx default output
  fi

  # Stage: proofread (ollama)
  if [[ -s "$cp_proofread" ]]; then
    log_info "Proofread checkpoint found, skipping: ${cp_proofread}"
    cp "$cp_proofread" "$interim_proofread"
  else
    log_info "Running proofread stage"
    run_ollama "$proofread_prompt" "$interim_asr" "$interim_proofread"
    log_info "Copying proofread result to checkpoint: ${cp_proofread}"
    cp "$interim_proofread" "$cp_proofread"
  fi

  # Stage: summarize (ollama)
  log_info "Running summarize stage"
  run_ollama "$summarize_prompt" "$interim_proofread" "$interim_summary"
  log_info "Copying summary result to checkpoint: ${cp_summary}"
  cp "$interim_summary" "$cp_summary"

  # Requirement 9: cleanup interim files on success
  log_info "Cleaning up interim files for base: ${base}"
  rm -f "${INTERIM_DIR}/${base}"*

  log_info "Done. Results in: ${video_dir}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
