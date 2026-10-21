#!/usr/bin/env python3
# Renders the "Felt" cue set into Resources/Sounds, the small sounds the app
# makes while you use it. Run: python3 scripts/make_cue_sounds.py
#
#   SayCtrlStart.wav  the dictation key goes down: a fifth, rising
#   SayCtrlStop.wav   the key comes up: the same fifth, falling
#   SayCtrlMatch.wav  a command ran, or "scratch that" took: an A major triad
#   SayCtrlNudge.wav  a tap too short to be dictation: one quiet high tick
#   SayCtrlMiss.wav   every error: a minor sixth going down
#
# Every note is the same pluck as the welcome chime (make_welcome_sound.py),
# so the whole app sounds like one instrument: soft felt on a string rather
# than a beep. Standard library only, so it regenerates anywhere.
import math
import os
import struct
import wave

RATE = 44100

# Notes as (frequency Hz, start s, gain, length s). The gains are relative
# across the whole set, not just within a file: every file gets the same
# master level below, which is how Nudge stays about 8 dB under Start. (Its
# 0.14 looks close to Start's 0.24, but Start is two notes that overlap and
# Nudge is one short one: 0.10 measured 11 dB down, too faint to register.)
CUES = {
    "SayCtrlStart": [(659.25, 0.0, 0.22, 0.45), (880.0, 0.07, 0.24, 0.6)],
    "SayCtrlStop": [(880.0, 0.0, 0.20, 0.45), (659.25, 0.07, 0.22, 0.6)],
    "SayCtrlMatch": [(880.0, 0.0, 0.18, 0.9), (1108.73, 0.045, 0.15, 0.9),
                     (1318.51, 0.09, 0.13, 1.0)],
    "SayCtrlNudge": [(987.77, 0.0, 0.14, 0.22)],
    "SayCtrlMiss": [(440.0, 0.0, 0.22, 0.55), (349.23, 0.11, 0.20, 0.85)],
}

# How loud Start is, as its loudest 50 ms, in dBFS. This is what the previous
# cue set measured (its Start peaked at -19 dBFS): these play at full system
# volume over whatever you are listening to, so the new set lands where the
# old one did instead of at a -3 dBFS peak, which would be some 15 dB louder.
START_LOUDNESS_DB = -26.8
REFERENCE = "SayCtrlStart"


def lowpass_coef(freq):
    return 1 - math.exp(-2 * math.pi * freq / RATE)


def pluck(out, freq, at, vol, length):
    """Sine with a little triangle octave and a faint third partial, a 5 ms
    attack and an exponential fall to -60 dB at `length`, through a lowpass
    closing from 3.2 kHz to 700 Hz as the note dies — the felt."""
    start, n = int(at * RATE), int(length * RATE)
    y = 0.0
    for i in range(n):
        t = i / RATE
        env = min(1.0, t / 0.005) * math.exp(-6.9 * t / length)
        tri = 2 / math.pi * math.asin(math.sin(2 * math.pi * freq * 2 * t))
        x = (math.sin(2 * math.pi * freq * t) + 0.22 * tri
             + 0.06 * math.sin(2 * math.pi * freq * 3.01 * t))
        cut = 3200 * (700 / 3200) ** min(1.0, t / length)
        y += lowpass_coef(cut) * (x - y)
        out[start + i] += vol * env * y


def room(dry, wet_level=0.16):
    """A small, short room: four damped feedback combs in parallel and two
    allpasses after them (Schroeder's recipe at Freeverb's tunings). Enough
    that a cue doesn't stop dead, gone well inside half a second."""
    n = len(dry)
    combs = [0.0] * n
    for d in (1116, 1188, 1277, 1356):
        buf = [0.0] * n
        y = 0.0
        a = lowpass_coef(3000)
        for i in range(n):
            fed = buf[i - d] if i >= d else 0.0
            y += a * (fed - y)           # the damping: highs die first
            buf[i] = dry[i] + 0.6 * y
            combs[i] += y / 4
    for d, g in ((556, 0.5), (441, 0.5)):
        buf = [0.0] * n
        res = [0.0] * n
        for i in range(n):
            fed = buf[i - d] if i >= d else 0.0
            buf[i] = combs[i] + g * fed
            res[i] = fed - g * buf[i]
        combs = res
    return [x + wet_level * w for x, w in zip(dry, combs)]


def render(notes):
    end = max(at + length for _, at, _, length in notes)
    out = [0.0] * int((end + 1.0) * RATE)   # a second of room for the tail
    for freq, at, vol, length in notes:
        pluck(out, freq, at, vol, length)
    return room(out)


def loudness(x):
    """The loudest 50 ms, as RMS: what the ear takes from a cue this short."""
    w = int(0.05 * RATE)
    best = 0.0
    for s in range(0, max(1, len(x) - w), w // 4):
        best = max(best, sum(v * v for v in x[s:s + w]) / w)
    return math.sqrt(best)


def finish(x):
    """Cut the tail where it falls below -60 dB of the peak, then a 5 ms fade
    so the cut doesn't click."""
    peak = max(abs(v) for v in x)
    last = max(i for i, v in enumerate(x) if abs(v) >= peak * 10 ** (-60 / 20))
    fade = int(0.005 * RATE)
    x = x[:last + 1 + fade]
    for i in range(fade):
        x[len(x) - fade + i] *= 1 - (i + 1) / fade
    return x


rendered = {name: render(notes) for name, notes in CUES.items()}

# One master gain for the whole set: first peak-normalised so the loudest cue
# would sit at -3 dBFS (the note gains then carry across files as written),
# then trimmed so Start comes out as loud as the set it replaces.
loudest = max(max(abs(v) for v in x) for x in rendered.values())
gain = 10 ** (-3 / 20) / loudest
gain *= 10 ** (START_LOUDNESS_DB / 20) / (loudness(rendered[REFERENCE]) * gain)

folder = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "Resources", "Sounds"))
for name, x in rendered.items():
    x = finish([v * gain for v in x])
    path = os.path.join(folder, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, v)) * 32767)) for v in x))
    peak = max(abs(v) for v in x)
    print(f"Wrote {path}  {len(x) / RATE:.2f} s, peak {20 * math.log10(peak):.1f} dBFS")
