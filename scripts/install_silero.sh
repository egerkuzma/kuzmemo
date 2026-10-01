#!/bin/zsh
# Sets up the Silero neural voice for Kuzmemo: a small Python environment with torch, and the Russian model (v4_ru,
# about 40 MB). Everything goes to ~/Library/Application Support/Kuzmemo/silero; nothing else on the Mac is touched (pip's
# own cache, which would live elsewhere, is switched off for that reason).
#
#   scripts/install_silero.sh
#
# Needs Python 3.10 or newer (for example: brew install python@3.13) and a network connection (about 100 MB to download,
# about 750 MB on disk afterwards).
# Safe to run again: whatever is already there and verified is kept.
# The Silero models are licensed CC BY-NC-SA 4.0: fine for personal use.
set -euo pipefail

DIR="$HOME/Library/Application Support/Kuzmemo/silero"
MODEL="$DIR/v4_ru.pt"
MODEL_URL="https://models.silero.ai/models/tts/ru/v4_ru.pt"
# The model is a Python pickle (torch.package), and loading one runs whatever code is in it: the file is only used when it is
# exactly the one this script was written for. The sum is that of the copy that has been in use since April 2026, which
# loads and speaks; it was not compared with a second download. When Silero replaces the file, the sum has to be updated by
# hand after looking at what changed.
MODEL_SHA256="896ab96347d5bd781ab97959d4fd6885620e5aab52405d3445626eb7c1414b00"
mkdir -p "$DIR"

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1 }

# 1. The model (v4_ru.pt) is downloaded from Silero's own server and checked.
if [ -s "$MODEL" ] && [ "$(sha_of "$MODEL")" != "$MODEL_SHA256" ]; then
  echo "model: the file in place is not the expected one (damaged, or changed); fetching it again"
  rm -f "$MODEL"
fi
if [ ! -s "$MODEL" ]; then
  echo "model: downloading $MODEL_URL"
  curl -fL --progress-bar -o "$MODEL.part" "$MODEL_URL"
  if [ "$(sha_of "$MODEL.part")" != "$MODEL_SHA256" ]; then
    rm -f "$MODEL.part"
    echo "the downloaded model is not the file this script was written for (changed upstream, or damaged on the way): it was not installed" >&2
    exit 1
  fi
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
# --no-cache-dir: pip would otherwise keep every download in ~/Library/Caches/pip, outside this folder. The ranges are the
# majors this was made with (torch 2, numpy 1 or 2): a later major may break loading the model.
"$DIR/venv/bin/pip" install --quiet --no-cache-dir --upgrade pip
"$DIR/venv/bin/pip" install --quiet --no-cache-dir "torch>=2.2,<3" "numpy>=1.26,<3" # numpy is optional for torch, but without it torch warns on every start

# 3. Check that the model loads and has its voices.
"$DIR/venv/bin/python" - "$MODEL" <<'PY'
import sys, torch
model = torch.package.PackageImporter(sys.argv[1]).load_pickle("tts_models", "model")
print("ok: torch", torch.__version__, "voices", [name for name in model.speakers if name != "random"])
PY
echo "done: choose Silero in Kuzmemo → Settings → Speech (Silero speaks Russian only)"
