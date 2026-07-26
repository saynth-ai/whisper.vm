# FreePBX Voicemail → Whisper Transcription → Email

Transcribes each voicemail left on a FreePBX/Asterisk system with a **locally-run
Whisper** ([whisper.cpp](https://github.com/ggml-org/whisper.cpp)) and puts the
transcript at the top of the voicemail email FreePBX already sends to the user.
No cloud service, no audio leaves the box.

## How it works

FreePBX/Asterisk already builds the voicemail-to-email message — correct
recipient, subject, body, and the `.wav` attachment — and pipes it to a
configurable **`mailcmd`** (normally `/usr/sbin/sendmail -t`). We insert a
wrapper in front of sendmail:

```
   voicemail left
        │
        ▼
  Asterisk builds the email  ──(pipe)──►  vm-mailcmd.py
                                              │  1. extract WAV attachment
                                              │  2. resample 8k→16k (sox/ffmpeg)
                                              │  3. Whisper transcribe (local or Docker)
                                              │  4. inject transcript into body
                                              ▼
                                        /usr/sbin/sendmail -t  ──►  user's inbox
```

Because we reuse Asterisk's own message, the email **is** the FreePBX email
(same From/To/subject/branding); we only enrich the body.

**Fail-safe:** if Whisper errors, times out, or there's no attachment, the
**original email is delivered unchanged** — a voicemail notification is never
lost because transcription failed.

## Layout

```
freepbx-whisper-vm/
├── scripts/
│   ├── install.sh          # build whisper.cpp natively + install wrapper (run as root on PBX)
│   ├── vm-transcribe.sh     # audio file → transcript text (local binary OR Docker HTTP)
│   ├── vm-mailcmd.py        # the mailcmd wrapper FreePBX pipes email into
│   └── test-transcribe.sh   # end-to-end test, does NOT touch the live PBX
├── docker/
│   ├── Dockerfile           # whisper.cpp HTTP server image
│   └── docker-compose.yml   # runs it on 127.0.0.1:8088
└── config/
    └── whisper.env          # backend + paths (installed to /etc/whisper-vm/whisper.env)
```

## Install — Option A: native whisper.cpp (recommended for a PBX)

Run on the PBX **as root**:

```bash
cd freepbx-whisper-vm
sudo MODEL=base.en scripts/install.sh
```

This builds whisper.cpp into `/opt/whisper.cpp`, downloads the model, installs
the scripts to `/opt/whisper-vm/`, and writes `/etc/whisper-vm/whisper.env`.

Model sizes (pick per CPU/accuracy): `tiny.en` (fastest) · **`base.en`** (good
default) · `small.en` · `medium.en` (most accurate, slow on CPU).

## Install — Option B: Docker whisper.cpp server

Run the transcription engine in a container instead of building on the host:

```bash
cd freepbx-whisper-vm/docker
docker compose up -d --build          # serves 127.0.0.1:8088
```

Then still install the wrapper scripts on the PBX host (they call the container
over loopback) and set the backend to http in `/etc/whisper-vm/whisper.env`:

```
WHISPER_BACKEND=http
WHISPER_URL=http://127.0.0.1:8088/inference
```

The wrapper script must live on the PBX host itself because Asterisk executes
`mailcmd` locally — only the heavy Whisper inference is containerized.

## Wire it into FreePBX

1. **Attach audio to email** (required — the wrapper transcribes the attachment):
   FreePBX GUI → **Settings → Voicemail Admin → Settings** →
   *Attach voicemail to Email = Yes* (or per-extension under *Applications →
   Extensions → Voicemail*).

2. **Point `mailcmd` at the wrapper.**
   - If your FreePBX version exposes a mail-command field in *Voicemail Admin*,
     set it to `/opt/whisper-vm/vm-mailcmd.py`.
   - Otherwise add it to Asterisk's voicemail config via the FreePBX-safe
     `_custom` include so it survives regeneration. Create/edit
     `/etc/asterisk/voicemail.conf` `[general]` is managed by FreePBX; instead
     put the override where FreePBX won't clobber it and reload:
     ```
     ; /etc/asterisk/vm_general.inc  (included by voicemail.conf [general])
     mailcmd=/opt/whisper-vm/vm-mailcmd.py
     ```
     (Check your generated `voicemail.conf` for the exact `#include` it already
     pulls in; drop the `mailcmd=` line into that included file.)

3. **Reload:**
   ```bash
   fwconsole reload
   # or: asterisk -rx "voicemail reload"
   ```

4. **Leave a test voicemail.** Watch it work:
   ```bash
   tail -f /var/log/asterisk/vm-transcribe.log
   ```

## Test before going live

Runs the whole pipeline with sendmail stubbed out — nothing is emailed, the
live PBX is untouched:

```bash
# use a real Asterisk voicemail wav...
scripts/test-transcribe.sh /var/spool/asterisk/voicemail/default/1001/INBOX/msg0000.wav
# ...or let it synthesize a sample (needs say/espeak/pico2wave)
scripts/test-transcribe.sh
```

It prints the transcript, then shows the delivered email so you can confirm the
transcript block was injected above the body and the WAV is still attached.

You can also just test the engine on any audio file:

```bash
/opt/whisper-vm/vm-transcribe.sh /path/to/audio.wav
```

## Notes & tuning

- **Audio format:** Asterisk voicemail is 8 kHz; the transcriber resamples to
  16 kHz mono with `sox` (preferred) or `ffmpeg`. One of those must be present.
- **Language:** defaults to English (`WHISPER_LANG=en`, `.en` models). For other
  languages use a multilingual model (`base`, `small`…) and set `WHISPER_LANG`.
- **Latency:** transcription runs when the email is sent, so the email arrives a
  few seconds later than before. `TRANSCRIBE_TIMEOUT` (default 120s) caps it; on
  timeout the original email is sent.
- **Alternative trigger:** instead of `mailcmd`, Asterisk's `externnotify` can
  run a script on every new voicemail — but it doesn't carry the message file
  cleanly and you'd have to send a *second* email, duplicating FreePBX's. The
  `mailcmd` approach here enriches the single email FreePBX already sends, which
  is why it's the default.
```
