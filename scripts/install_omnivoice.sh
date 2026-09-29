#!/bin/zsh
# Sets up the experimental "My voice" engine for Kuzmemo: omnivoice.cpp (a native, Metal-accelerated port of the OmniVoice
# text-to-speech model that can clone a voice from a short recording) and its quantised weights. Everything goes to
# ~/Library/Application Support/Kuzmemo/omnivoice; nothing else on the Mac is touched, and nothing of any other app is read.
#
#   scripts/install_omnivoice.sh
#
# Needs git, cmake and the Xcode command line tools (clang++ and the Metal compiler), and a network connection: about
# 40 MB of source and 945 MB of weights to download, about 1.1 GB on disk afterwards. Safe to run again: whatever is
# already there and verified is kept.
#
# The program (omnivoice.cpp) is MIT licensed. The weights are the OmniVoice model by k2-fsa in GGUF form: CC-BY-NC 4.0,
# that is non-commercial use only, which is fine for a personal app. Clone only your own voice.
set -euo pipefail

DIR="${KUZMEMO_OMNIVOICE_DIR:-$HOME/Library/Application Support/Kuzmemo/omnivoice}"
SRC_URL="https://github.com/ServeurpersoCom/omnivoice.cpp.git"
SRC_SHA="53e6c2066150802ad3cd4b655b31c696e78e0019" # master of 2026-09-28; change it only after trying the new one
HF_REPO="Serveurperso/OmniVoice-GGUF"
HF_REV="017094167b5c9ed565a5076ac9b3b93c5ecf5c73"
typeset -A SIZE SHA256
SIZE[omnivoice-base-Q8_0.gguf]=656395008
SHA256[omnivoice-base-Q8_0.gguf]="2882d887921798aea13d45236556bdf8012842ab6f8cd2690943eead6289f298"
SIZE[omnivoice-tokenizer-Q8_0.gguf]=288889600
SHA256[omnivoice-tokenizer-Q8_0.gguf]="75204fa566a8e30984e7a1066da6557184c9fd099c8f1bc0cb5b9415edfec255"

for tool in git cmake clang++; do
  command -v "$tool" >/dev/null || { echo "missing: $tool (brew install cmake; xcode-select --install)" >&2; exit 1; }
done
mkdir -p "$DIR/models"

# 1. The program, at a pinned commit, built with Metal.
if [ ! -x "$DIR/build/tts-server" ] || [ "$(cat "$DIR/.built" 2>/dev/null || true)" != "$SRC_SHA" ]; then
  echo "program: fetching omnivoice.cpp $SRC_SHA"
  rm -rf "$DIR/src" "$DIR/build"
  mkdir -p "$DIR/src"
  git -C "$DIR/src" init --quiet
  git -C "$DIR/src" remote add origin "$SRC_URL"
  git -C "$DIR/src" fetch --quiet --depth 1 origin "$SRC_SHA"
  git -C "$DIR/src" checkout --quiet FETCH_HEAD
  git -C "$DIR/src" submodule update --quiet --init --depth 1 --recursive
  GENERATOR=()
  command -v ninja >/dev/null && GENERATOR=(-G Ninja)
  echo "program: building (a minute or two)"
  cmake -S "$DIR/src" -B "$DIR/build" "${GENERATOR[@]}" -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON -DCMAKE_OSX_ARCHITECTURES=arm64 >"$DIR/build.log" 2>&1
  cmake --build "$DIR/build" -j "$(sysctl -n hw.ncpu)" >>"$DIR/build.log" 2>&1 || { tail -20 "$DIR/build.log" >&2; exit 1; }
  echo "$SRC_SHA" >"$DIR/.built"
fi
for tool in omnivoice-tts omnivoice-codec tts-server; do
  [ -x "$DIR/build/$tool" ] || { echo "the build did not produce $tool (see $DIR/build.log)" >&2; exit 1; }
done
grep -q "Metal framework found" "$DIR/build.log" 2>/dev/null || echo "note: this build has no Metal (see $DIR/build.log); it will run on the CPU and slowly" >&2

# 2. The weights, checked against the sizes and SHA-256 sums that Hugging Face publishes for this revision.
for file in ${(k)SIZE}; do
  target="$DIR/models/$file"
  if [ -f "$target" ] && [ "$(stat -f %z "$target")" = "${SIZE[$file]}" ] && [ "$(shasum -a 256 "$target" | cut -d' ' -f1)" = "${SHA256[$file]}" ]; then
    echo "weights: $file is in place"
    continue
  fi
  echo "weights: downloading $file ($((SIZE[$file] / 1048576)) MB)"
  curl -fL --progress-bar -C - --retry 3 -o "$target.part" "https://huggingface.co/$HF_REPO/resolve/$HF_REV/$file"
  if [ "$(shasum -a 256 "$target.part" | cut -d' ' -f1)" != "${SHA256[$file]}" ]; then
    rm -f "$target.part"
    echo "the checksum of $file does not match; try again" >&2
    exit 1
  fi
  mv "$target.part" "$target"
done

# 3. Warm-up. The first run of a newly built program compiles its GPU kernels, which takes 15 to 20 seconds; done here, once,
# it does not make the first spoken answer slow. (The kernels of the voice encoder are compiled when a voice is recorded.)
WARM="$DIR/.warm"
if [ "$(cat "$WARM" 2>/dev/null || true)" != "$SRC_SHA" ]; then
  echo "warm-up: compiling the GPU kernels (about 20 seconds, once)"
  TMP="$(mktemp -d)"
  if echo "Проверка." | "$DIR/build/omnivoice-tts" --model "$DIR/models/omnivoice-base-Q8_0.gguf" \
       --codec "$DIR/models/omnivoice-tokenizer-Q8_0.gguf" --lang Russian --steps 4 -o "$TMP/warm.wav" >/dev/null 2>&1 && [ -s "$TMP/warm.wav" ]; then
    echo "$SRC_SHA" >"$WARM"
  else
    echo "note: the warm-up run failed; the first spoken answer may be slow or fail" >&2
  fi
  rm -rf "$TMP"
fi

# 4. A short self-check: the program starts and prints its version.
"$DIR/build/omnivoice-tts" --help 2>&1 | sed -n 1p || true # prints its version; the help text itself ends with a non-zero status
echo "done: $DIR"
echo "next: Kuzmemo → Settings → Speech → My voice (not built yet: this installs the parts)"
