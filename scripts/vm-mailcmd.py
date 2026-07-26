#!/usr/bin/env python3
"""
vm-mailcmd.py  --  Whisper transcription mailcmd wrapper for FreePBX/Asterisk.

Asterisk builds the voicemail-to-email message (recipient, subject, body and the
WAV attachment) and pipes it to whatever `mailcmd` is configured. Normally that is
`/usr/sbin/sendmail -t`. Point `mailcmd` here instead and this script will:

  1. read the full RFC822 email from stdin (as FreePBX generated it),
  2. find the audio attachment and transcribe it with Whisper,
  3. insert the transcript at the top of the message body,
  4. hand the modified message off to the real sendmail.

FAIL-SAFE: if anything goes wrong (no attachment, whisper error, timeout...),
the ORIGINAL, unmodified email is still delivered. A voicemail notification is
never lost because transcription failed.

Config via environment (see config/whisper.env), with defaults:
  SENDMAIL_BIN        real MTA command      (default: /usr/sbin/sendmail -t)
  TRANSCRIBE_SCRIPT   path to vm-transcribe.sh
  TRANSCRIBE_TIMEOUT  seconds before giving up   (default: 120)
  TRANSCRIBE_LOG      log file                   (default: /var/log/asterisk/vm-transcribe.log)
"""
import os
import sys
import shlex
import subprocess
import tempfile
import datetime
from email import message_from_bytes
from email.message import Message

def load_env_file():
    """Populate os.environ from the config file (existing env wins).
    Asterisk invokes mailcmd with a bare environment, so without this the
    wrapper would only ever see the built-in defaults."""
    candidates = [
        "/etc/whisper-vm/whisper.env",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "config", "whisper.env"),
    ]
    for path in candidates:
        if not os.path.isfile(path):
            continue
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                if line.startswith("export "):
                    line = line[len("export "):]
                key, _, val = line.partition("=")
                key = key.strip()
                val = val.strip().strip('"').strip("'")
                os.environ.setdefault(key, val)  # existing env wins


load_env_file()

SENDMAIL_BIN = os.environ.get("SENDMAIL_BIN", "/usr/sbin/sendmail -t")
TRANSCRIBE_SCRIPT = os.environ.get(
    "TRANSCRIBE_SCRIPT",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "vm-transcribe.sh"),
)
TRANSCRIBE_TIMEOUT = int(os.environ.get("TRANSCRIBE_TIMEOUT", "120"))
LOG = os.environ.get("TRANSCRIBE_LOG", "/var/log/asterisk/vm-transcribe.log")


def log(msg):
    line = "%s %s\n" % (datetime.datetime.now().isoformat(timespec="seconds"), msg)
    try:
        with open(LOG, "a") as fh:
            fh.write(line)
    except OSError:
        sys.stderr.write(line)


def send(raw_bytes):
    """Deliver the message bytes via the real MTA."""
    subprocess.run(shlex.split(SENDMAIL_BIN), input=raw_bytes, check=True)


def find_audio_part(msg):
    """Return the first part that looks like an audio attachment, else None."""
    for part in msg.walk():
        if part.is_multipart():
            continue
        ctype = (part.get_content_type() or "").lower()
        fname = (part.get_filename() or "").lower()
        if ctype.startswith("audio/") or fname.endswith((".wav", ".gsm", ".mp3", ".ogg")):
            return part
    return None


def transcribe(audio_bytes, suffix):
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tf:
        tf.write(audio_bytes)
        path = tf.name
    try:
        out = subprocess.run(
            ["bash", TRANSCRIBE_SCRIPT, path],
            capture_output=True,
            timeout=TRANSCRIBE_TIMEOUT,
        )
        if out.returncode != 0:
            log("transcribe rc=%d stderr=%s" % (out.returncode,
                out.stderr.decode('utf-8', 'replace').strip()[:500]))
            return None  # hard failure -> caller delivers original untouched
        return out.stdout.decode("utf-8", "replace").strip()
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def inject_transcript(msg, transcript):
    """Prepend the transcript block to the first text/plain part (and html if present)."""
    block_txt = (
        "----- Voicemail Transcription (Whisper) -----\n"
        "%s\n"
        "---------------------------------------------\n\n"
    ) % (transcript if transcript else "[no speech detected]")

    injected = False
    for part in msg.walk():
        if part.get_content_type() == "text/plain" and not part.get_filename():
            charset = part.get_content_charset() or "utf-8"
            try:
                body = part.get_payload(decode=True).decode(charset, "replace")
            except Exception:
                body = ""
            part.set_payload(block_txt + body, charset=charset)
            injected = True
            break

    if not injected:
        # No text/plain part found — nothing to enrich; caller falls back to original.
        raise ValueError("no text/plain body part to inject into")

    # Also enrich an HTML alternative if one exists.
    esc = (transcript or "[no speech detected]").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    block_html = ('<div style="border:1px solid #ccc;padding:8px;margin-bottom:12px;'
                  'font-family:sans-serif"><b>Voicemail Transcription (Whisper)</b><br>%s</div>') % esc
    for part in msg.walk():
        if part.get_content_type() == "text/html" and not part.get_filename():
            charset = part.get_content_charset() or "utf-8"
            try:
                body = part.get_payload(decode=True).decode(charset, "replace")
            except Exception:
                continue
            if "<body" in body.lower():
                idx = body.lower().find("<body")
                idx = body.find(">", idx) + 1
                body = body[:idx] + block_html + body[idx:]
            else:
                body = block_html + body
            part.set_payload(body, charset=charset)
            break

    return msg


def main():
    raw = sys.stdin.buffer.read()

    # From here on, any failure => deliver the original email untouched.
    try:
        msg = message_from_bytes(raw)  # type: Message
        audio = find_audio_part(msg)
        if audio is None:
            log("no audio attachment found; delivering original")
            send(raw)
            return

        payload = audio.get_payload(decode=True)
        if not payload:
            log("audio part had no decodable payload; delivering original")
            send(raw)
            return

        fname = audio.get_filename() or "vm.wav"
        suffix = os.path.splitext(fname)[1] or ".wav"
        transcript = transcribe(payload, suffix)
        if transcript is None:
            log("transcription failed; delivering original")
            send(raw)
            return
        log("transcribed %d bytes -> %d chars: %s"
            % (len(payload), len(transcript), transcript[:200]))

        modified = inject_transcript(msg, transcript)
        send(modified.as_bytes())
    except Exception as e:  # noqa: BLE001  -- deliberately broad; must not drop mail
        log("ERROR %r; delivering original email unchanged" % e)
        try:
            send(raw)
        except Exception as e2:  # noqa: BLE001
            log("FATAL could not send original: %r" % e2)
            sys.exit(1)


if __name__ == "__main__":
    main()
