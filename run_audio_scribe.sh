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
# MODEL and AGENT are resolved in main() after argument parsing.
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
  -h, --help         Show this help message
  -v, --verbose      Enable verbose output (set -x)
  -a, --agent AGENT  LLM agent: ollama or claude (default: ollama)
  -m, --model MODEL  Model name in the selected agent's format
                     (default: ollama=gemma4:12b-it-qat, claude=sonnet)

ENV:
  HF_TOKEN   HuggingFace token (required for diarization; falls back to dummy)
  MODEL      ollama model, used when --model is not given (default: gemma4:12b-it-qat)
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

# strip_markdown_fence <file>
# Defensive normalization: even with the custom --system-prompt asking for no
# code fences, claude occasionally still wraps the whole reply in a single
# ```...``` block. Checkpoints are only validated by "non-empty" (see main()),
# so a fence-wrapped SRT would otherwise be treated as complete and never
# self-heal on retry. Strip a leading and matching trailing fence line if the
# first line begins with ``` (optionally with a language tag like ```srt) and
# the last line is exactly triple-backticks.
function strip_markdown_fence() {
  [[ $# -eq 1 ]] || err "${LINENO}" "strip_markdown_fence requires 1 arg"
  local file="$1"

  [[ -s "$file" ]] || return 0
  head -n1 "$file" | grep -qE '^```' || return 0
  tail -n1 "$file" | grep -qE '^```[[:space:]]*$' || return 0

  local stripped
  stripped=$(mktemp)
  register_tmp "$stripped"
  sed '1d;$d' "$file" >"$stripped"
  mv "$stripped" "$file"
}

function run_claude() {
  [[ $# -eq 3 ]] || err "${LINENO}" "run_claude requires 3 args"
  local template_file="$1" input_file="$2" output_file="$3"

  command -v claude >/dev/null 2>&1 || err "${LINENO}" "claude CLI not found in PATH"

  local prompt_file
  prompt_file=$(mktemp)
  register_tmp "$prompt_file"
  readonly prompt_file

  # Step 1: build prompt by replacing {{INPUT}} with file contents
  jq -Rs --rawfile template "$template_file" \
    '. as $input | $template | split("{{INPUT}}") | join($input)' \
    "$input_file" >"$prompt_file"

  # Step 2: run claude in non-interactive mode. Unlike ollama, the output is
  # not streamed; it arrives all at once when generation completes. The prompt
  # goes via stdin to avoid argument length limits.
  # This must be a pure text transform, not an agentic session, so repo context
  # (CLAUDE.md, hooks, plugins, cwd/git info, etc.) must not leak into the
  # output and corrupt the proofread/summary checkpoints:
  #   --safe-mode disables CLAUDE.md/skills/plugins/hooks/MCP auto-discovery
  #     while keeping normal OAuth/API-key auth working (unlike --bare, which
  #     restricts auth strictly to ANTHROPIC_API_KEY/apiKeyHelper and breaks
  #     login for OAuth-based accounts).
  #   --tools "" disables all tool access, so the model cannot read/glob/grep
  #     repo files even if the transcript content tried to instruct it to.
  #   --system-prompt replaces (not appends to) the default system prompt.
  #     The default system prompt embeds dynamic per-machine sections (cwd,
  #     git status/branch/log) even under --safe-mode; only a full
  #     replacement keeps the repo name and branch from leaking into output
  #     (verified: with only --safe-mode --tools "", the model could still
  #     name this repo and its current branch). This also suppresses
  #     conversational preamble/postamble and markdown code fences.
  local system_prompt="You are a plain text transformation tool with no knowledge of any project, repository, codebase, or filesystem. Output only the exact content requested by the user instructions. Do not add any preamble, explanation, markdown code fences, or closing remarks before or after the output."
  readonly system_prompt
  log_info "Running claude -p (model=${MODEL}); output appears when done"
  if ! claude -p --safe-mode --tools "" --system-prompt "$system_prompt" \
    --model "$MODEL" <"$prompt_file" >"$output_file"; then
    err "${LINENO}" "claude -p failed (model=${MODEL})"
  fi

  strip_markdown_fence "$output_file"

  if [[ ! -s "$output_file" ]]; then
    err "${LINENO}" "claude returned an empty response (model=${MODEL})"
  fi
}

function run_agent() {
  case $AGENT in
  ollama) run_ollama "$@" ;;
  claude) run_claude "$@" ;;
  *) err "${LINENO}" "Unknown agent: ${AGENT}" ;;
  esac
}

function main() {
  local verbose=0
  local input_file=""
  local agent="ollama" agent_model=""

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
    -m | --model)
      if [[ $# -lt 2 ]]; then
        log_err "Missing value for $1"
        usage >&2
        exit 1
      fi
      agent_model="$2"
      shift 2
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

  case $agent in
  ollama | claude) ;;
  *)
    log_err "Invalid agent: ${agent} (expected: ollama or claude)"
    usage >&2
    exit 1
    ;;
  esac

  if [[ -z "$agent_model" ]]; then
    if [[ "$agent" == "claude" ]]; then
      agent_model="sonnet"
    else
      agent_model="${MODEL:-gemma4:12b-it-qat}"
    fi
  fi
  AGENT="$agent"
  MODEL="$agent_model"
  # shellcheck disable=SC2034
  readonly AGENT MODEL

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

  # Stage: proofread (LLM agent)
  if [[ -s "$cp_proofread" ]]; then
    log_info "Proofread checkpoint found, skipping: ${cp_proofread}"
    cp "$cp_proofread" "$interim_proofread"
  else
    log_info "Running proofread stage"
    run_agent "$proofread_prompt" "$interim_asr" "$interim_proofread"
    log_info "Copying proofread result to checkpoint: ${cp_proofread}"
    cp "$interim_proofread" "$cp_proofread"
  fi

  # Stage: summarize (LLM agent)
  log_info "Running summarize stage"
  run_agent "$summarize_prompt" "$interim_proofread" "$interim_summary"
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
