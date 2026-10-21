#!/usr/bin/env python3
# Renders the first-run sounds into Resources/Sounds. Run:
#   python3 scripts/make_onboarding_sounds.py
#
# They were tuned in design/welcome-redesign.html (Web Audio) and are the same
# voices here, sample for sample in spirit: a sine with a quick attack and an
# exponential fall, a quieter triangle an octave up for shimmer, and a small
# room reverb under everything.
#
#   SayCtrlWelcome.wav   the entrance, timed to Onboarding.swift's timeline:
#                        a pop as the pill appears (0 s), a rising note on
#                        each of "Welcome", "to", "SayControl" (0.52, 0.82,
#                        1.12 s), and the chord with a breath of air as the
#                        pill opens into the window (1.9 s)
#   SayCtrlSignedIn.wav  two notes up, when the account lands
#   SayCtrlGrant*.wav    one bell per switch, rising down the list
#   SayCtrlAllSet.wav    the chord alone: every switch on
#   SayCtrlOpen.wav      the setup window growing into the app
#   SayCtrlPop.wav       the pill saying hello, the window coming back
#
# Standard library only, so it regenerates anywhere.
import math
import os
import random
import struct
import wave

RATE = 44100
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "Resources", "Sounds")
random.seed(11)


class Track:
    def __init__(self, seconds):
        self.buf = [0.0] * int(RATE * seconds)

    def voice(self, kind, f, at, attack, peak, decay, glide_to=None):
        """One oscillator: exponential ramp up to `peak` over `attack`, then
        down over `decay` — Web Audio's exponentialRampToValueAtTime pair."""
        start = int(at * RATE)
        n = int((attack + decay + 0.05) * RATE)
        phase = 0.0
        lo = 0.0001
        for i in range(n):
            j = start + i
            if j >= len(self.buf):
                break
            t = i / RATE
            freq = f
            if glide_to and t < 0.09:
                freq = f * (glide_to / f) ** (t / 0.09)
            elif glide_to:
                freq = glide_to
            phase = (phase + freq / RATE) % 1.0
            if kind == "sine":
                x = math.sin(2 * math.pi * phase)
            else:  # triangle
                x = 4 * abs(phase - 0.5) - 1
            if t < attack:
                g = lo * (peak / lo) ** (t / attack)
            else:
                g = peak * (lo / peak) ** min(1.0, (t - attack) / decay)
            self.buf[j] += x * g

    def air(self, at, length=1.0, peak=0.05):
        """Band-passed noise whose centre sweeps 300 Hz → 2.6 kHz over 0.7 s:
        the breath as the pill opens into the window."""
        start = int(at * RATE)
        x1 = x2 = y1 = y2 = 0.0
        for i in range(int(length * RATE)):
            j = start + i
            if j >= len(self.buf):
                break
            t = i / RATE
            fc = 300 * (2600 / 300) ** min(1.0, t / 0.7)
            q = 0.8
            w = 2 * math.pi * fc / RATE
            alpha = math.sin(w) / (2 * q)
            b0, b2 = alpha, -alpha
            a0, a1, a2 = 1 + alpha, -2 * math.cos(w), 1 - alpha
            x = random.uniform(-1, 1)
            y = (b0 * x + b2 * x2 - a1 * y1 - a2 * y2) / a0
            x2, x1, y2, y1 = x1, x, y1, y
            if t < 0.3:
                g = 0.0001 * (peak / 0.0001) ** (t / 0.3)
            else:
                g = peak * (0.0001 / peak) ** min(1.0, (t - 0.3) / 0.6)
            self.buf[j] += y * g

    # The instruments.
    def pop(self, at):
        self.voice("sine", 880, at, 0.004, 0.26, 0.22, glide_to=600)
        self.voice("tri", 1760, at, 0.002, 0.04, 0.07)

    def word(self, at, f):
        self.voice("sine", f, at, 0.003, 0.09, 0.16)
        self.voice("tri", f * 2, at, 0.002, 0.02, 0.06)

    def bell(self, at, f):
        self.voice("sine", f, at, 0.004, 0.11, 1.3)
        self.voice("tri", f * 2, at, 0.003, 0.025, 0.4)

    def bloom(self, at):
        for k, (f, g) in enumerate([(130.81, .09), (261.63, .10), (392.00, .08), (659.25, .07), (987.77, .05)]):
            self.voice("sine", f, at + k * 0.04, 0.05, g, 2.6)
            self.voice("tri", f, at + k * 0.04, 0.06, g * 0.25, 1.4)
        self.air(at)

    def open(self, at):
        self.voice("sine", 392.00, at, 0.01, 0.07, 1.1)
        self.voice("sine", 587.33, at + 0.1, 0.01, 0.07, 1.4)
        self.voice("tri", 1174.66, at + 0.1, 0.004, 0.015, 0.5)

    def render(self, name, wet=0.32, master=0.7):
        dry = self.buf
        rev = reverb(dry)
        mix = [master * (d + wet * r) for d, r in zip(dry, rev)]
        peak = max(1e-9, max(abs(v) for v in mix))
        if peak > 0.9:   # never clip; quieter cues stay as quiet as they were tuned
            mix = [v * 0.9 / peak for v in mix]
        # Trim trailing silence, keep a short tail.
        end = len(mix)
        while end > RATE // 10 and abs(mix[end - 1]) < 1e-4:
            end -= 1
        mix = mix[:min(len(mix), end + RATE // 20)]
        path = os.path.join(OUT_DIR, name)
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, v)) * 32767)) for v in mix))
        print(f"{name}: {len(mix) / RATE:.2f} s, peak {min(peak, 0.9):.2f}")


def reverb(x):
    """A small Schroeder room: four damped combs in parallel, two allpasses
    in series. Stands in for the page's 2.4 s noise impulse."""
    combs = [(1557, .84), (1617, .83), (1491, .85), (1422, .86)]
    out = [0.0] * len(x)
    for delay, fb in combs:
        buf = [0.0] * delay
        idx = 0
        store = 0.0
        for i, v in enumerate(x):
            y = buf[idx]
            store = y * 0.8 + store * 0.2   # damping
            buf[idx] = v + store * fb
            idx = (idx + 1) % delay
            out[i] += y * 0.25
    for delay, g in [(225, .5), (556, .5)]:
        buf = [0.0] * delay
        idx = 0
        for i, v in enumerate(out):
            b = buf[idx]
            y = -v + b
            buf[idx] = v + b * g
            idx = (idx + 1) % delay
            out[i] = y
    return out


# The entrance: pop, three words, the chord.
t = Track(5.0)
t.pop(0.0)
for at, f in [(0.52, 659.25), (0.82, 783.99), (1.12, 987.77)]:
    t.word(at, f)
t.bloom(1.9)
t.render("SayCtrlWelcome.wav")

t = Track(1.2)
t.word(0.0, 783.99)
t.word(0.11, 1046.5)
t.render("SayCtrlSignedIn.wav")

# One bell per switch, named by pitch; the list picks them in order down the
# rows (C5, E5, G5, B5 — D5 slots in when the Voice row shows).
for name, f in [("C5", 523.25), ("D5", 587.33), ("E5", 659.25), ("G5", 783.99), ("B5", 987.77)]:
    t = Track(2.0)
    t.bell(0.0, f)
    t.render(f"SayCtrlGrant{name}.wav")

t = Track(3.4)
t.bloom(0.0)
t.render("SayCtrlAllSet.wav")

t = Track(2.2)
t.open(0.0)
t.render("SayCtrlOpen.wav")

t = Track(0.8)
t.pop(0.0)
t.render("SayCtrlPop.wav")
