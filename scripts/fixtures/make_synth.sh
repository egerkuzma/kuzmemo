#!/usr/bin/env bash
# Generates synthetic 16 kHz mono WAV fixtures from phrases.txt with a macOS system voice (Milena, a Russian voice),
# plus digital silence and quiet pink noise for hallucination checks. Output goes to scripts/fixtures/out (gitignored).
# The files are only for driving the pipeline in tests: synthetic speech is cleaner than a real person's.
# Needs ffmpeg (brew install ffmpeg) and the voice Milena (System Settings > Accessibility > Spoken Content > System Voice >
# Manage Voices > Russian).
set -euo pipefail
cd "$(dirname "$0")"
command -v ffmpeg >/dev/null || { echo "ffmpeg is needed for the silence and noise files: brew install ffmpeg" >&2; exit 1; }
voices="$(say -v '?')" # not piped into grep -q: with pipefail its early exit would look like a failure
grep -q '^Milena ' <<<"$voices" || { echo "the Russian system voice Milena is needed: System Settings > Accessibility > Spoken Content > System Voice > Manage Voices" >&2; exit 1; }
mkdir -p out/synth
while IFS='|' read -r id cat text; do
  [ -z "${id:-}" ] && continue
  [ "$cat" = "noise" ] && continue
  say -v Milena -o "out/synth/$id.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "out/synth/$id.aiff" "out/synth/$id.wav"
  rm -f "out/synth/$id.aiff"
done < phrases.txt
# short spoken answers to clarifying questions (answers.txt: id|text)
while IFS='|' read -r id text; do
  [ -z "${id:-}" ] && continue
  say -v Milena -o "out/synth/$id.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "out/synth/$id.aiff" "out/synth/$id.wav"
  rm -f "out/synth/$id.aiff"
done < answers.txt
ffmpeg -loglevel error -y -f lavfi -i anullsrc=r=16000:cl=mono -t 3 -c:a pcm_s16le out/synth/silence3.wav
ffmpeg -loglevel error -y -f lavfi -i "anoisesrc=d=5:c=pink:r=16000:a=0.02" -c:a pcm_s16le out/synth/noise5.wav
ls -1 out/synth | wc -l | xargs echo "fixtures:"
