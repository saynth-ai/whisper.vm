#!/usr/bin/env bash
#
# test-transcribe.sh [audio.wav]
#
# End-to-end test WITHOUT touching the live PBX:
#   1. transcribe an audio file with the configured Whisper backend
#   2. build a synthetic FreePBX-style voicemail email (WAV attached)
#   3. run it through vm-mailcmd.py with sendmail STUBBED OUT, and show the
#      resulting email so you can confirm the transcript was injected.
#
# If no audio file is given, tries to synthesize one with say/espeak/pico2wave.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

AUDIO="${1:-}"

if [ -z "$AUDIO" ]; then
    echo ">> no audio given; synthesizing a sample"
    SAMPLE="$TMP/sample.wav"
    TEXT="Hi, this is a test voicemail. Please call me back at five five five, one two three four. Thanks."
    if command -v say >/dev/null 2>&1; then            # macOS
        say -o "$TMP/s.aiff" "$TEXT"
        (command -v ffmpeg >/dev/null && ffmpeg -nostdin -loglevel error -y -i "$TMP/s.aiff" -ar 8000 -ac 1 "$SAMPLE") \
            || (command -v sox >/dev/null && sox "$TMP/s.aiff" -r 8000 -c 1 "$SAMPLE")
    elif command -v pico2wave >/dev/null 2>&1; then
        pico2wave -w "$SAMPLE" "$TEXT"
    elif command -v espeak >/dev/null 2>&1; then
        espeak -w "$SAMPLE" "$TEXT"
    else
        echo "!! no TTS found (say/pico2wave/espeak). Pass a .wav path instead:" >&2
        echo "   $0 /var/spool/asterisk/voicemail/default/1001/INBOX/msg0000.wav" >&2
        exit 1
    fi
    AUDIO="$SAMPLE"
fi

echo
echo "=== 1. Direct transcription ==================================="
TRANSCRIPT="$(bash "$HERE/vm-transcribe.sh" "$AUDIO")"
echo "Transcript: $TRANSCRIPT"

echo
echo "=== 2. Building synthetic FreePBX voicemail email ============="
B64="$(base64 < "$AUDIO" | tr -d '\n' | fold -w 76)"
EMAIL="$TMP/vm-email.eml"
{
cat <<'HDR'
To: user@example.com
From: "Voicemail System" <voicemail@pbx.example.com>
Subject: New voicemail from 5551234 in mailbox 1001
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="VMBOUNDARY"

--VMBOUNDARY
Content-Type: text/plain; charset=US-ASCII

Dear user:

	just wanted to let you know you were just left a 8 second long message
in mailbox 1001 from 5551234, on Monday, July 27, 2026 at 10:00:00 AM.

--VMBOUNDARY
Content-Type: audio/x-wav; name="msg0000.wav"
Content-Transfer-Encoding: base64
Content-Disposition: attachment; filename="msg0000.wav"

HDR
echo "$B64"
cat <<'FTR'

--VMBOUNDARY--
FTR
} > "$EMAIL"

echo
echo "=== 3. Piping through vm-mailcmd.py (sendmail stubbed) ========"
# Stub sendmail: dump whatever the wrapper hands off into a file.
STUB="$TMP/fake-sendmail.sh"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
cat > "$TMP/delivered.eml"
EOF
chmod +x "$STUB"

SENDMAIL_BIN="$STUB" \
TRANSCRIBE_SCRIPT="$HERE/vm-transcribe.sh" \
TRANSCRIBE_LOG="$TMP/log.txt" \
python3 "$HERE/vm-mailcmd.py" < "$EMAIL"

echo
echo "--- delivered email (attachment truncated) -------------------"
python3 - "$TMP/delivered.eml" <<'PY'
import sys
from email import message_from_binary_file
with open(sys.argv[1], "rb") as fh:
    msg = message_from_binary_file(fh)
for part in msg.walk():
    ct = part.get_content_type()
    if ct == "text/plain" and not part.get_filename():
        print("[text/plain body]\n" + part.get_payload(decode=True).decode("utf-8","replace"))
    elif not part.is_multipart():
        print("[attachment %s %s: %d bytes]" %
              (ct, part.get_filename(), len(part.get_payload(decode=True) or b"")))
PY

echo "--- wrapper log ----------------------------------------------"
cat "$TMP/log.txt" 2>/dev/null || true
echo
echo "PASS if the text/plain body above starts with the transcription block."
