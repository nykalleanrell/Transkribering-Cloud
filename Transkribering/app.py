#!/usr/bin/env python3
"""
Transkribering – lokal Flask-server
Använder KBLab/kb-whisper-large för svenska och openai/whisper-medium för engelska.
Ingen talaridentifiering — appen visar texten i 2-minutersblock.
"""

import os
import subprocess
import tempfile
from flask import Flask, request, jsonify

app = Flask(__name__)

_pipelines: dict = {}

MODEL_EN = os.environ.get("WHISPER_MODEL_EN", "openai/whisper-medium")

# Svenska modeller per storlek
SV_MODELS = {
    "medium": "KBLab/kb-whisper-medium",
    "small":  "KBLab/kb-whisper-small",
}


def _device():
    import torch
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


def _dtype():
    import torch
    # float16 är snabbare på CUDA; CPU har inget native float16-stöd
    return torch.float16 if _device() == "cuda" else torch.float32


def get_pipeline(language: str, model_size: str = "medium"):
    if language == "sv":
        model_id = SV_MODELS.get(model_size, SV_MODELS["medium"])
    else:
        model_id = MODEL_EN
    if model_id not in _pipelines:
        import torch
        from transformers import pipeline
        print(f"Laddar modell '{model_id}'...", flush=True)
        dev   = _device()
        dtype = _dtype()
        _pipelines[model_id] = pipeline(
            "automatic-speech-recognition",
            model=model_id,
            device=dev,
            torch_dtype=dtype,
        )
        print(f"Modell '{model_id}' laddad på {dev} ({dtype}).", flush=True)
    return _pipelines[model_id]


@app.route("/health")
def health():
    return jsonify({"status": "ok"})


@app.route("/transcribe", methods=["POST"])
def transcribe():
    if "file" not in request.files:
        return jsonify({"error": "Ingen fil skickades"}), 400

    audio_file  = request.files["file"]
    language    = request.form.get("language", "sv")
    model_size  = request.form.get("model_size", "medium")

    # batch_size=1 förhindrar OOM; chunk_length balanserar hastighet och minne
    chunk_length  = 60  if model_size == "small" else 120
    stride_length = 10  if model_size == "small" else 20
    batch_size    = 1

    ext = os.path.splitext(audio_file.filename or "audio.wav")[1] or ".wav"
    tmp_fd, tmp_path = tempfile.mkstemp(suffix=ext)
    os.close(tmp_fd)

    wav_path = None
    try:
        audio_file.save(tmp_path)

        # Konvertera till 16 kHz mono WAV med macOS inbyggda afconvert.
        # soundfile klarar alltid WAV — ingen ffmpeg eller Homebrew behövs.
        wav_fd, wav_path = tempfile.mkstemp(suffix=".wav")
        os.close(wav_fd)
        subprocess.run(
            ["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000",
             "-c", "1", tmp_path, wav_path],
            check=True, capture_output=True
        )

        pipe = get_pipeline(language, model_size)

        generate_kwargs = {"task": "transcribe"}
        if language != "auto":
            generate_kwargs["language"] = language

        result = pipe(
            wav_path,
            generate_kwargs=generate_kwargs,
            return_timestamps=True,
            chunk_length_s=chunk_length,
            stride_length_s=stride_length,
            batch_size=batch_size,
        )

        segments = []
        for ch in (result.get("chunks") or []):
            ts   = ch.get("timestamp") or (None, None)
            text = (ch.get("text") or "").strip()
            if not text:
                continue
            start = float(ts[0]) if ts[0] is not None else 0.0
            end   = float(ts[1]) if ts[1] is not None else start + 1.0
            segments.append({
                "start":       start,
                "end":         end,
                "speaker":     "speaker_0",
                "speakerName": "Talare 1",
                "text":        text,
            })

        return jsonify({"segments": segments})

    except Exception as exc:
        import traceback
        traceback.print_exc()
        return jsonify({"error": str(exc)}), 500

    finally:
        for p in [tmp_path, wav_path]:
            if p:
                try:
                    os.unlink(p)
                except OSError:
                    pass


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    print(f"Startar Transkribering-server på port {port}...", flush=True)
    get_pipeline("sv")
    app.run(host="127.0.0.1", port=port, debug=False, threaded=False)
