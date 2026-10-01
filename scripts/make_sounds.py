#!/usr/bin/env python3
"""Synthesizes Kuzmemo's own alert chimes (Resources/Sounds/Kuzmemo-<id>.wav) with additive and FM synthesis and the
standard library only. The files are not committed (*.wav is ignored); scripts/run_app.sh runs this when any of them is
missing, and it is the place to change them.

    scripts/make_sounds.py              makes every chime (and the folder for them)
    scripts/make_sounds.py --missing    prints the chimes that are not there yet; exit status 1 when there are some

Every chime peaks at about -4 dBFS, starts with a short fade-in (no click) and ends in a fade-out, and is a mono
44.1 kHz 16-bit WAV, which the system notification sound, NSSound and AVAudioPlayer all accept.
"""
import math
import os
import struct
import sys
import wave

RATE = 44_100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "Sounds")
PEAK = 0.62  # about -4 dBFS
# Every chime this file makes (the names the app's sound catalog asks for).
CHIMES = ("bell", "drop", "gong", "marimba", "sonar", "glass", "melody", "soft")


def missing():
    return [name for name in CHIMES if not os.path.isfile(os.path.join(OUT, f"Kuzmemo-{name}.wav"))
            or os.path.getsize(os.path.join(OUT, f"Kuzmemo-{name}.wav")) == 0]


if "--missing" in sys.argv[1:]:
    left = missing()
    print(" ".join(left))
    sys.exit(1 if left else 0)
os.makedirs(OUT, exist_ok=True)  # a fresh clone has no such folder: the files in it are not committed


def silence(seconds):
    return [0.0] * int(seconds * RATE)


def mix(*tracks):
    length = max(len(t) for t in tracks)
    out = [0.0] * length
    for track in tracks:
        for i, x in enumerate(track):
            out[i] += x
    return out


def delayed(track, seconds):
    return silence(seconds) + track


def tone(freq, seconds, partials=((1.0, 1.0, 0.0),), attack=0.004, decay=6.0):
    """A struck tone: partials are (frequency ratio, amplitude, extra decay per second)."""
    n = int(seconds * RATE)
    out = [0.0] * n
    for ratio, amp, extra in partials:
        w = 2 * math.pi * freq * ratio / RATE
        d = decay + extra
        for i in range(n):
            t = i / RATE
            env = (1 - math.exp(-t / attack)) * math.exp(-d * t)
            out[i] += amp * env * math.sin(w * i)
    return out


def finish(track, name):
    peak = max(abs(x) for x in track) or 1.0
    gain = PEAK / peak
    n = len(track)
    fade_in = int(0.004 * RATE)
    fade_out = int(0.06 * RATE)
    samples = []
    for i, x in enumerate(track):
        g = gain
        if i < fade_in:
            g *= i / fade_in
        if i > n - fade_out:
            g *= max(0.0, (n - i) / fade_out)
        samples.append(max(-1.0, min(1.0, x * g)))
    path = os.path.join(OUT, f"Kuzmemo-{name}.wav")
    with wave.open(path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(b"".join(struct.pack("<h", int(s * 32767)) for s in samples))
    rms = math.sqrt(sum(s * s for s in samples) / n)
    print(f"{name:8s} {n / RATE:5.2f} s  peak {max(abs(s) for s in samples):.2f}  rms {rms:.3f}")


# --- the chimes --------------------------------------------------------------------------------------------

# A handbell: Risset's inharmonic partials, the high ones dying faster.
bell_partials = [(0.56, 1.0, 0.0), (0.92, 0.9, 0.3), (1.19, 0.65, 0.6), (1.71, 0.5, 1.0), (2.0, 0.9, 1.4),
                 (2.74, 0.35, 2.0), (3.0, 0.3, 2.6), (3.76, 0.2, 3.4), (4.07, 0.15, 4.0)]
finish(tone(440, 2.6, bell_partials, decay=1.5), "bell")

# A water drop: a sine that falls in pitch very quickly, plus a faint overtone.
def drop():
    n = int(0.55 * RATE)
    out, phase = [], 0.0
    for i in range(n):
        t = i / RATE
        f = 620 + 900 * math.exp(-t / 0.035)
        phase += 2 * math.pi * f / RATE
        env = (1 - math.exp(-t / 0.002)) * math.exp(-t / 0.11)
        out.append(env * (math.sin(phase) + 0.25 * math.sin(2 * phase)))
    return out
finish(drop(), "drop")

# A soft gong: low, slow to bloom, long to fade.
gong_partials = [(1.0, 1.0, 0.0), (1.52, 0.55, 0.4), (2.31, 0.38, 0.8), (2.98, 0.3, 1.2), (4.18, 0.16, 1.8), (5.43, 0.1, 2.4)]
finish(tone(196, 3.4, gong_partials, attack=0.03, decay=1.1), "gong")

# A marimba figure: three wooden notes rising (C - E - G).
def marimba_note(freq):
    return tone(freq, 0.7, [(1.0, 1.0, 0.0), (4.0, 0.32, 9.0), (9.9, 0.08, 20.0)], attack=0.002, decay=5.5)
finish(mix(marimba_note(523.25), delayed(marimba_note(659.25), 0.16), delayed(marimba_note(783.99), 0.32)), "marimba")

# A sonar ping with two fading echoes.
def ping():
    return tone(1180, 0.32, [(1.0, 1.0, 0.0), (2.0, 0.12, 6.0)], attack=0.003, decay=9.0)
p = ping()
finish(mix(p, delayed([x * 0.42 for x in p], 0.30), delayed([x * 0.18 for x in p], 0.60)), "sonar")

# Glass: bright FM with a decaying modulation index.
def glass():
    n = int(1.5 * RATE)
    out = []
    for i in range(n):
        t = i / RATE
        index = 3.2 * math.exp(-t / 0.09)
        env = (1 - math.exp(-t / 0.002)) * math.exp(-t / 0.42)
        out.append(env * math.sin(2 * math.pi * 1320 * t + index * math.sin(2 * math.pi * 1320 * 3.5 * t)))
    return out
finish(glass(), "glass")

# A rising melody of three soft notes (G - B - D), with a little air around them.
def soft_note(freq, seconds=0.9):
    return tone(freq, seconds, [(1.0, 1.0, 0.0), (2.0, 0.22, 1.5), (3.0, 0.06, 3.0)], attack=0.012, decay=3.4)
melody = mix(soft_note(392.0), delayed(soft_note(493.88), 0.22), delayed(soft_note(587.33, 1.3), 0.44))
echo = delayed([x * 0.22 for x in melody], 0.24)
finish(mix(melody, echo), "melody")

# A soft two-note signal (E - A).
finish(mix(soft_note(659.25, 0.7), delayed(soft_note(880.0, 0.9), 0.20)), "soft")

assert not missing(), f"chimes not made: {missing()}"
