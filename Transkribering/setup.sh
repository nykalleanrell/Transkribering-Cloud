#!/bin/bash
# setup.sh — installerar Python-paketen for Transkribering (KBLab/kb-whisper-medium + small)
# Protokoll: PROGRESS:<0.0-1.0>:<text>  |  DONE  |  ERROR:<text>

APP_SUPPORT="$HOME/Library/Application Support/Transkribering"
VENV="$APP_SUPPORT/venv"
MARKER="$VENV/.setup_kbwhisper_v2"   # v2 → tvingar ominstallation vid modellbyte

log() { echo "$1"; }

# ── Redan installerat? ─────────────────────────────────────────────────────────
if [ -f "$MARKER" ]; then
    log "PROGRESS:1.0:Redan installerat"
    log "DONE"
    exit 0
fi

# ── Hitta Python 3.9+ ─────────────────────────────────────────────────────────
log "PROGRESS:0.03:Soker efter Python..."

PYTHON=""
for candidate in \
    /opt/homebrew/bin/python3.12 \
    /opt/homebrew/bin/python3.11 \
    /opt/homebrew/bin/python3.10 \
    /opt/homebrew/bin/python3.9 \
    /opt/homebrew/bin/python3 \
    /usr/local/bin/python3.12 \
    /usr/local/bin/python3.11 \
    /usr/local/bin/python3.10 \
    /usr/local/bin/python3 \
    /usr/bin/python3
do
    if [ -x "$candidate" ]; then
        OK=$("$candidate" -c "import sys; print('yes' if sys.version_info >= (3,9) else 'no')" 2>/dev/null || echo "no")
        if [ "$OK" = "yes" ]; then
            PYTHON="$candidate"
            break
        fi
    fi
done

if [ -z "$PYTHON" ]; then
    log "ERROR:Python 3.9+ hittades inte. Installera Homebrew och kor: brew install python"
    exit 1
fi

log "PROGRESS:0.06:Hittade $PYTHON"

# ── Skapa virtuell miljo (rensa gammal vid uppgradering) ─────────────────────
log "PROGRESS:0.10:Forbereder Python-miljo..."

mkdir -p "$APP_SUPPORT" || {
    log "ERROR:Kunde inte skapa $APP_SUPPORT"
    exit 1
}

# Ta bort gammal venv om den innehaller openai-whisper (inte kompatibel)
if [ -f "$VENV/lib/python3"*/site-packages/whisper/__init__.py ] 2>/dev/null || \
   "$VENV/bin/python3" -c "import whisper" 2>/dev/null; then
    log "PROGRESS:0.15:Tar bort gammal installation..."
    rm -rf "$VENV"
fi

if [ ! -d "$VENV" ]; then
    "$PYTHON" -m venv "$VENV" 2>&1 || {
        log "ERROR:Kunde inte skapa venv med $PYTHON"
        exit 1
    }
fi

VENV_PY="$VENV/bin/python3"
VENV_PIP="$VENV/bin/pip"

log "PROGRESS:0.18:Uppgraderar pip..."
"$VENV_PY" -m pip install --quiet --quiet --upgrade pip setuptools wheel 2>/dev/null || true

# ── Installera paket ──────────────────────────────────────────────────────────
log "PROGRESS:0.22:Installerar Flask..."
"$VENV_PIP" install --quiet --quiet --no-cache-dir "flask>=3.0" 2>/dev/null || {
    log "ERROR:Flask-installation misslyckades"
    exit 1
}

log "PROGRESS:0.28:Installerar PyTorch..."
"$VENV_PIP" install --quiet --quiet --no-cache-dir "torch>=2.1" 2>/dev/null || {
    log "ERROR:PyTorch-installation misslyckades"
    exit 1
}

log "PROGRESS:0.50:Installerar Transformers och ljudbibliotek..."
"$VENV_PIP" install --quiet --quiet --no-cache-dir \
    "transformers>=4.40" \
    "accelerate>=0.26" \
    "soundfile" \
    2>/dev/null || {
    log "ERROR:Transformers-installation misslyckades"
    exit 1
}

# ── Verifiera ─────────────────────────────────────────────────────────────────
log "PROGRESS:0.70:Verifierar installation..."
VERIFY=$("$VENV_PY" -c "import transformers, flask, soundfile; print('ok')" 2>&1)
if [ "$VERIFY" != "ok" ]; then
    log "ERROR:Verifiering misslyckades: $VERIFY"
    exit 1
fi

# ── Forladda KBLab/kb-whisper-medium (~1.5 GB) ────────────────────────────────
log "PROGRESS:0.75:Laddar ned KBLab/kb-whisper-medium (~1.5 GB) — 5-10 minuter..."

"$VENV_PY" -c "
import time, threading
from transformers import pipeline

done = threading.Event()

def heartbeat():
    steps = [0.75, 0.77, 0.79, 0.81, 0.83]
    i = 0
    while not done.is_set():
        time.sleep(20)
        if not done.is_set():
            p = steps[min(i, len(steps)-1)]
            print(f'PROGRESS:{p}:Laddar ned kb-whisper-medium... (detta tar tid)', flush=True)
            i += 1

t = threading.Thread(target=heartbeat, daemon=True)
t.start()
pipeline('automatic-speech-recognition', model='KBLab/kb-whisper-medium')
done.set()
print('kb-whisper-medium klar', flush=True)
" 2>&1 || {
    log "ERROR:Nedladdning av KBLab/kb-whisper-medium misslyckades. Kontrollera internetanslutningen."
    exit 1
}

# ── Forladda KBLab/kb-whisper-small (~0.5 GB) ─────────────────────────────────
log "PROGRESS:0.85:Laddar ned KBLab/kb-whisper-small (~0.5 GB) — 2-3 minuter..."

"$VENV_PY" -c "
import time, threading
from transformers import pipeline

done = threading.Event()

def heartbeat():
    steps = [0.85, 0.87, 0.89]
    i = 0
    while not done.is_set():
        time.sleep(20)
        if not done.is_set():
            p = steps[min(i, len(steps)-1)]
            print(f'PROGRESS:{p}:Laddar ned kb-whisper-small... (detta tar tid)', flush=True)
            i += 1

t = threading.Thread(target=heartbeat, daemon=True)
t.start()
pipeline('automatic-speech-recognition', model='KBLab/kb-whisper-small')
done.set()
print('kb-whisper-small klar', flush=True)
" 2>&1 || {
    log "ERROR:Nedladdning av KBLab/kb-whisper-small misslyckades. Kontrollera internetanslutningen."
    exit 1
}

# ── Forladda openai/whisper-medium (~1.5 GB) ──────────────────────────────────
log "PROGRESS:0.92:Laddar ned openai/whisper-medium (~1.5 GB) — for engelska och auto-detect..."

"$VENV_PY" -c "
import time, threading
from transformers import pipeline

done = threading.Event()

def heartbeat():
    steps = [0.92, 0.94, 0.96, 0.98]
    i = 0
    while not done.is_set():
        time.sleep(20)
        if not done.is_set():
            p = steps[min(i, len(steps)-1)]
            print(f'PROGRESS:{p}:Laddar ned whisper-medium... (detta tar tid)', flush=True)
            i += 1

t = threading.Thread(target=heartbeat, daemon=True)
t.start()
pipeline('automatic-speech-recognition', model='openai/whisper-medium')
done.set()
print('whisper-medium klar', flush=True)
" 2>&1 || {
    log "ERROR:Nedladdning av openai/whisper-medium misslyckades. Kontrollera internetanslutningen."
    exit 1
}

# ── Klar ──────────────────────────────────────────────────────────────────────
touch "$MARKER"
log "PROGRESS:1.0:Installation klar!"
log "DONE"
