#!/usr/bin/env bash
#
# install.sh -- build whisper.cpp natively on a FreePBX/Sangoma (RHEL-family) or
# Debian PBX host and install the transcription mailcmd wrapper.
#
# Run as root on the PBX.  For the container route, use docker/ instead.
#
set -euo pipefail

WHISPER_DIR="${WHISPER_DIR:-/opt/whisper.cpp}"
MODEL="${MODEL:-base.en}"          # tiny.en | base.en | small.en | medium.en ...
INSTALL_DIR="/opt/whisper-vm"
CONF_DIR="/etc/whisper-vm"
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

echo ">> installing build dependencies"
if command -v dnf >/dev/null 2>&1; then
    dnf install -y git gcc-c++ make cmake sox ffmpeg-free python3 curl || \
    dnf install -y git gcc-c++ make cmake sox python3 curl
elif command -v yum >/dev/null 2>&1; then
    yum install -y git gcc-c++ make cmake sox python3 curl
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y git g++ make cmake sox ffmpeg python3 curl
else
    echo "unsupported package manager; install git/g++/cmake/sox/python3 manually" >&2
fi

echo ">> cloning + building whisper.cpp into $WHISPER_DIR"
if [ ! -d "$WHISPER_DIR/.git" ]; then
    git clone --depth 1 https://github.com/ggml-org/whisper.cpp "$WHISPER_DIR"
fi
cd "$WHISPER_DIR"
cmake -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build -j --config Release --target whisper-cli

echo ">> downloading model: $MODEL"
bash ./models/download-ggml-model.sh "$MODEL"

echo ">> installing scripts into $INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$CONF_DIR"
install -m 0755 "$SRC_DIR/scripts/vm-transcribe.sh" "$INSTALL_DIR/vm-transcribe.sh"
install -m 0755 "$SRC_DIR/scripts/vm-mailcmd.py"    "$INSTALL_DIR/vm-mailcmd.py"

echo ">> writing config $CONF_DIR/whisper.env"
cat > "$CONF_DIR/whisper.env" <<EOF
WHISPER_BACKEND=local
WHISPER_BIN=$WHISPER_DIR/build/bin/whisper-cli
WHISPER_MODEL=$WHISPER_DIR/models/ggml-$MODEL.bin
WHISPER_LANG=en
TRANSCRIBE_SCRIPT=$INSTALL_DIR/vm-transcribe.sh
TRANSCRIBE_TIMEOUT=120
SENDMAIL_BIN=/usr/sbin/sendmail -t
TRANSCRIBE_LOG=/var/log/asterisk/vm-transcribe.log
EOF

# Make the env available to the scripts (they also read /etc/whisper-vm/whisper.env).
ln -sf "$CONF_DIR/whisper.env" "$INSTALL_DIR/../whisper-vm-env" 2>/dev/null || true
touch /var/log/asterisk/vm-transcribe.log 2>/dev/null || true
chown asterisk:asterisk /var/log/asterisk/vm-transcribe.log 2>/dev/null || true

cat <<EOF

===============================================================================
Done. whisper.cpp built at: $WHISPER_DIR/build/bin/whisper-cli
Model:                      $WHISPER_DIR/models/ggml-$MODEL.bin
mailcmd wrapper:            $INSTALL_DIR/vm-mailcmd.py

NEXT STEPS (FreePBX):
  1. Test the engine:
       $INSTALL_DIR/vm-transcribe.sh /path/to/some.wav

  2. In FreePBX GUI: Settings > Voicemail Admin > Settings
       - "Attach voicemail to Email"  = Yes   (audio must be attached)
       - set the mail command / "mailcmd" to:
             $INSTALL_DIR/vm-mailcmd.py
     If your FreePBX version has no mailcmd field, add to
     /etc/asterisk/voicemail.conf under [general] (via the
     _custom include so FreePBX won't overwrite it):
             mailcmd=$INSTALL_DIR/vm-mailcmd.py

  3. Reload:  fwconsole reload    (or: asterisk -rx "voicemail reload")

  4. Leave a test voicemail. Transcript appears at the top of the email
     FreePBX sends to the user. Watch: tail -f /var/log/asterisk/vm-transcribe.log
===============================================================================
EOF
