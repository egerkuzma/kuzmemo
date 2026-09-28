#!/usr/bin/env bash
# Clones the WhisperKit large-v3-turbo model and its tokenizer into Kuzmemo's own data folder using
# APFS clones (cp -c: no extra disk space). Reading ~/Documents from a new app triggers a macOS
# "access to Documents" prompt, so the app must only ever read its own copy.
# The originals belong to other apps (the reference project) and are never modified or deleted.
set -euo pipefail

SRC="${KUZMEMO_MODEL_SRC:-$HOME/Documents/huggingface}"
DEST="${KUZMEMO_MODEL_DEST:-$HOME/Library/Application Support/Kuzmemo/huggingface}"
VARIANT="${KUZMEMO_MODEL_VARIANT:-openai_whisper-large-v3-v20240930_turbo}"
MODEL_REL="models/argmaxinc/whisperkit-coreml/$VARIANT"
TOK_REL="models/openai/whisper-large-v3"

[ -d "$SRC/$MODEL_REL" ] || { echo "model not found: $SRC/$MODEL_REL" >&2; exit 1; }
[ -d "$SRC/$TOK_REL" ] || { echo "tokenizer not found: $SRC/$TOK_REL" >&2; exit 1; }

mkdir -p "$DEST/models/argmaxinc/whisperkit-coreml" "$DEST/$TOK_REL"

if [ -d "$DEST/$MODEL_REL" ]; then
  echo "model already cloned: $DEST/$MODEL_REL"
else
  cp -c -R "$SRC/$MODEL_REL" "$DEST/models/argmaxinc/whisperkit-coreml/"
  echo "cloned model -> $DEST/$MODEL_REL"
fi

for f in config.json tokenizer.json tokenizer_config.json; do
  if [ -f "$DEST/$TOK_REL/$f" ]; then continue; fi
  cp -c "$SRC/$TOK_REL/$f" "$DEST/$TOK_REL/$f"
done
echo "tokenizer ready -> $DEST/$TOK_REL"
du -sh "$DEST" | awk '{print "logical size: " $1}'
