#!/usr/bin/env bash
#
# vm-transcribe.sh <audio-file>
#
# Transcribes an audio file with Whisper and prints the transcript to stdout.
# Handles resampling to 16 kHz mono (what Whisper expects) before inference.
#
# Two backends, selected via WHISPER_BACKEND:
#   local  -> run the whisper.cpp binary directly on this host (default)
#   http   -> POST the audio to a whisper.cpp server (e.g. the Docker container)
#
# Config via environment (see config/whisper.env):
#   WHISPER_BACKEND   local | http          (default: local)
#   WHISPER_BIN       path to whisper-cli/main binary   (local backend)
#   WHISPER_MODEL     path to ggml model .bin           (local backend)
#   WHISPER_LANG      language hint, e.g. en             (default: en)
#   WHISPER_THREADS   thread count                       (default: nproc)
#   WHISPER_URL       server inference URL               (http backend)
#
set -euo pipefail

# --- load config if present ------------------------------------------------
for f in /etc/whisper-vm/whisper.env "$(dirname "$0")/../config/whisper.env"; do
    # shellcheck disable=SC1090
    [ -f "$f" ] && . "$f"
done

WHISPER_BACKEND="${WHISPER_BACKEND:-local}"
WHISPER_BIN="${WHISPER_BIN:-/opt/whisper.cpp/build/bin/whisper-cli}"
WHISPER_MODEL="${WHISPER_MODEL:-/opt/whisper.cpp/models/ggml-base.en.bin}"
WHISPER_LANG="${WHISPER_LANG:-en}"
WHISPER_THREADS="${WHISPER_THREADS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
WHISPER_URL="${WHISPER_URL:-http://127.0.0.1:8088/inference}"

IN="${1:?usage: vm-transcribe.sh <audio-file>}"
[ -f "$IN" ] || { echo "audio file not found: $IN" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WAV16="$TMP/audio16k.wav"

# --- resample to 16kHz mono 16-bit PCM -------------------------------------
# whisper.cpp requires 16 kHz; Asterisk voicemail is usually 8 kHz.
if command -v sox >/dev/null 2>&1; then
    sox "$IN" -r 16000 -c 1 -b 16 "$WAV16" >/dev/null 2>&1
elif command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -nostdin -loglevel error -y -i "$IN" -ar 16000 -ac 1 -c:a pcm_s16le "$WAV16"
else
    echo "neither sox nor ffmpeg available for resampling" >&2
    exit 3
fi

# --- run inference ----------------------------------------------------------
case "$WHISPER_BACKEND" in
    local)
        [ -x "$WHISPER_BIN" ] || { echo "whisper binary not found/executable: $WHISPER_BIN" >&2; exit 4; }
        [ -f "$WHISPER_MODEL" ] || { echo "model not found: $WHISPER_MODEL" >&2; exit 4; }
        # -nt = no timestamps, print plain text to stdout
        "$WHISPER_BIN" \
            -m "$WHISPER_MODEL" \
            -f "$WAV16" \
            -l "$WHISPER_LANG" \
            -t "$WHISPER_THREADS" \
            -nt 2>/dev/null \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
            | grep -v '^$' \
            | tr '\n' ' ' \
            | sed 's/[[:space:]]\{2,\}/ /g; s/[[:space:]]*$//'
        ;;
    http)
        # whisper.cpp server: POST multipart form-data, returns JSON {"text": "..."}
        RESP="$(curl -s -f \
            -F "file=@${WAV16}" \
            -F "temperature=0.0" \
            -F "response_format=json" \
            "$WHISPER_URL")" || { echo "whisper server request failed: $WHISPER_URL" >&2; exit 5; }
        printf '%s' "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("text","").strip())'
        ;;
    *)
        echo "unknown WHISPER_BACKEND: $WHISPER_BACKEND" >&2
        exit 6
        ;;
esac
