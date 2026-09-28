"""Transcribe a WAV file with whisperx and write an SRT with speaker labels.

Usage: uv run --project <repo> <repo>/transcribe.py <input_wav> <output_dir>

The HuggingFace token is read from HF_TOKEN rather than an argument so that it
does not show up in the process list.
"""

import argparse
import gc
import os

import torch
from whisperx.alignment import align, load_align_model
from whisperx.asr import load_model
from whisperx.audio import load_audio
from whisperx.diarize import DiarizationPipeline, assign_word_speakers
from whisperx.log_utils import get_logger, setup_logging
from whisperx.utils import get_writer

MODEL_NAME = "large-v3-turbo"
LANGUAGE = "ja"
DEVICE = "cpu"
COMPUTE_TYPE = "int8"
BATCH_SIZE = 4
THREADS = 8
WRITER_ARGS = {"highlight_words": False, "max_line_count": None, "max_line_width": None}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Transcribe a WAV file with whisperx and write an SRT."
    )
    parser.add_argument("input_wav")
    parser.add_argument("output_dir")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    setup_logging("info")
    logger = get_logger(__name__)
    token = os.environ.get("HF_TOKEN")

    # faster-whisper (ctranslate2) has no MPS backend, so only diarization,
    # which runs on pyannote/torch, can use MPS.
    diarize_device = "mps" if torch.backends.mps.is_available() else "cpu"

    torch.set_num_threads(THREADS)
    os.makedirs(args.output_dir, exist_ok=True)

    model = load_model(
        MODEL_NAME,
        device=DEVICE,
        compute_type=COMPUTE_TYPE,
        language=LANGUAGE,
        threads=THREADS,
        use_auth_token=token,
    )
    audio = load_audio(args.input_wav)
    logger.info("Performing transcription...")
    result = model.transcribe(audio, batch_size=BATCH_SIZE, verbose=True)
    del model
    gc.collect()

    align_model, align_metadata = load_align_model(LANGUAGE, DEVICE)
    # The CLI skips alignment when nothing was transcribed; keep the same output.
    if result["segments"]:
        logger.info("Performing alignment...")
        result = align(result["segments"], align_model, align_metadata, audio, DEVICE)
    del align_model
    gc.collect()

    logger.info("Performing diarization...")
    logger.info(f"Diarization device: {diarize_device}")
    diarize_model = DiarizationPipeline(token=token, device=diarize_device)
    diarize_segments = diarize_model(audio)
    result = assign_word_speakers(diarize_segments, result)

    result["language"] = LANGUAGE
    writer = get_writer("srt", args.output_dir)
    writer(result, args.input_wav, WRITER_ARGS)
    logger.info("Finished writing SRT")


if __name__ == "__main__":
    main()
