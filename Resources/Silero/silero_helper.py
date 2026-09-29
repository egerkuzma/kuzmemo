#!/usr/bin/env python3
"""Kuzmemo's helper for the Silero neural Russian voice (https://github.com/snakers4/silero-models, model v4_ru).

The app keeps this process alive between phrases so that the model is loaded once. It speaks JSON lines:

    argv    silero_helper.py <path to v4_ru.pt>

    stdout  {"event": "ready", "speakers": [...], "torch": "2.11.0", "load_ms": 280}     the model is loaded
            {"event": "error", "error": "..."}                                          it cannot start (then it exits)
    stdin   {"id": "7", "op": "say", "text": "...", "speaker": "eugene", "rate": "medium", "sample_rate": 48000,
             "out": "/path/phrase.wav"}
    stdout  {"id": "7", "ok": true, "path": "/path/phrase.wav", "seconds": 3.2, "ms": 120}
            {"id": "7", "ok": false, "error": "..."}
    stdin   {"op": "quit"}

Needs torch and nothing else (no numpy, no scipy). The audio is written as a mono 16-bit WAV. Nothing but protocol lines
ever goes to stdout: anything else the libraries print is sent to stderr.
"""
import array
import json
import os
import re
import sys
import time
import wave

RATES = ("x-slow", "slow", "medium", "fast", "x-fast")
CHUNK = 220  # characters per synthesis call: the model is happiest with sentences


def main():
    # The protocol owns a private copy of stdout; whatever else prints (warnings from torch, say) goes to stderr.
    proto = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
    os.dup2(2, 1)
    sys.stdout = sys.stderr

    def send(message):
        proto.write(json.dumps(message, ensure_ascii=False) + "\n")
        proto.flush()

    if len(sys.argv) < 2 or not os.path.isfile(sys.argv[1]):
        send({"event": "error", "error": "model file not found: %s" % (sys.argv[1] if len(sys.argv) > 1 else "(none)")})
        return 2
    try:
        import torch
    except Exception as error:  # noqa: BLE001 - any import problem is reported the same way
        send({"event": "error", "error": "torch is not available: %s" % error})
        return 2

    started = time.time()
    try:
        torch.set_num_threads(max(2, min(4, os.cpu_count() or 4)))
        model = torch.package.PackageImporter(sys.argv[1]).load_pickle("tts_models", "model")
        model.to(torch.device("cpu"))
        speakers = [name for name in getattr(model, "speakers", []) if name != "random"]
    except Exception as error:  # noqa: BLE001
        send({"event": "error", "error": "the model cannot be loaded: %s" % error})
        return 2
    send({"event": "ready", "speakers": speakers, "torch": torch.__version__, "load_ms": int((time.time() - started) * 1000)})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except ValueError:
            continue
        op = request.get("op")
        if op == "quit":
            break
        if op != "say":
            continue
        identifier = request.get("id")
        try:
            send(dict(id=identifier, ok=True, **say(torch, model, speakers, request)))
        except Exception as error:  # noqa: BLE001 - one bad phrase must not stop the helper
            send({"id": identifier, "ok": False, "error": "%s" % error})
    return 0


def say(torch, model, speakers, request):
    began = time.time()
    text = (request.get("text") or "").strip()
    if not text:
        raise ValueError("empty text")
    speaker = request.get("speaker") or speakers[0]
    if speaker not in speakers:
        raise ValueError("unknown speaker %r (have: %s)" % (speaker, ", ".join(speakers)))
    rate = request.get("rate") if request.get("rate") in RATES else "medium"
    sample_rate = int(request.get("sample_rate") or 48000)
    if sample_rate not in (8000, 24000, 48000):
        sample_rate = 48000
    out = request["out"]

    pieces = []
    pause = torch.zeros(int(sample_rate * 0.16))
    with torch.no_grad():
        for chunk in split(text):
            if rate == "medium":
                audio = model.apply_tts(text=chunk, speaker=speaker, sample_rate=sample_rate, put_accent=True, put_yo=True)
            else:
                ssml = '<speak><prosody rate="%s">%s</prosody></speak>' % (rate, escape(chunk))
                audio = model.apply_tts(ssml_text=ssml, speaker=speaker, sample_rate=sample_rate, put_accent=True, put_yo=True)
            if pieces:
                pieces.append(pause)
            pieces.append(audio)
    audio = torch.cat(pieces)
    if audio.numel() < sample_rate // 20:
        raise ValueError("the voice produced no sound for this text")
    samples = array.array("h", (audio.clamp(-1, 1) * 32767).short().tolist())
    with wave.open(out, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(samples.tobytes())
    return {"path": out, "seconds": round(audio.numel() / sample_rate, 3), "ms": int((time.time() - began) * 1000)}


def split(text):
    """Sentences, packed into pieces of about CHUNK characters (a long sentence is cut at commas, then at spaces)."""
    sentences = [s.strip() for s in re.split(r"(?<=[.!?…])\s+|\n+", text) if s.strip()]
    pieces, current = [], ""
    for sentence in sentences:
        for part in cut(sentence):
            if current and len(current) + 1 + len(part) > CHUNK:
                pieces.append(current)
                current = part
            else:
                current = (current + " " + part).strip()
    if current:
        pieces.append(current)
    return pieces


def cut(sentence):
    if len(sentence) <= CHUNK:
        return [sentence]
    parts, current = [], ""
    for word in re.split(r"(?<=,)\s+|\s+", sentence):
        if current and len(current) + 1 + len(word) > CHUNK:
            parts.append(current)
            current = word
        else:
            current = (current + " " + word).strip()
    if current:
        parts.append(current)
    return parts


def escape(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


if __name__ == "__main__":
    sys.exit(main())
