#!/bin/zsh
# Sets up the Silero neural voice for Kuzmemo: a small Python environment with torch, and the Russian model (v4_ru,
# about 40 MB). Everything goes to ~/Library/Application Support/Kuzmemo/silero; nothing else on the Mac is touched.
#
#   scripts/install_silero.sh
#
# Needs Python 3.10 or newer (for example: brew install python@3.13) and a network connection (about 100 MB to download,
# about 750 MB on disk afterwards).
# Safe to run again: whatever is already there is kept.
# The Silero models are licensed CC BY-NC-SA 4.0: fine for personal use.
set -euo pipefail

DIR="$HOME/Library/Application Support/Kuzmemo/silero"
MODEL="$DIR/v4_ru.pt"
MODEL_URL="https://models.silero.ai/models/tts/ru/v4_ru.pt"
mkdir -p "$DIR"

# 1. The model (v4_ru.pt) is downloaded from Silero's own server.
if [ ! -s "$MODEL" ]; then
  echo "model: downloading $MODEL_URL"
  curl -fL --progress-bar -o "$MODEL.part" "$MODEL_URL"
  mv "$MODEL.part" "$MODEL"
fi

# 2. Python with torch.
if [ ! -x "$DIR/venv/bin/python" ]; then
  PY=""
  for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
    found="$(command -v "$candidate" || true)"
    [ -n "$found" ] || continue
    if "$found" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then PY="$found"; break; fi
  done
  if [ -z "$PY" ]; then
    echo "no Python 3.10 or newer found (brew install python@3.13)" >&2
    exit 1
  fi
  echo "python: $PY"
  "$PY" -m venv "$DIR/venv"
fi
echo "torch: installing (a few minutes the first time)"
"$DIR/venv/bin/pip" install --quiet --upgrade pip
"$DIR/venv/bin/pip" install --quiet torch numpy # numpy is optional for torch, but without it torch warns on every start

# 3. Check that the model loads and has its voices.
"$DIR/venv/bin/python" - "$MODEL" <<'PY'
import sys, torch
model = torch.package.PackageImporter(sys.argv[1]).load_pickle("tts_models", "model")
print("ok: torch", torch.__version__, "voices", [name for name in model.speakers if name != "random"])
PY
echo "done: choose Silero in Kuzmemo → Settings → Speech (Silero speaks Russian only)"
