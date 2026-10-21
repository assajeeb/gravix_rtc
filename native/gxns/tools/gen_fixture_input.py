#!/usr/bin/env python3
"""Writes tests/fixtures/noisy_speechlike_48k.pcm: 2 s, 48 kHz, mono, int16 LE.

Deterministic synthetic "noisy speech": a glottal pulse train (f0 110-220 Hz)
through three formant resonators, 4 Hz syllable envelope with pauses, plus
pink-ish noise and a 50 Hz hum. No real recordings are needed or shipped.

The golden output (tests/fixtures/rnnoise_v011_golden_48k.pcm) is produced by
building UPSTREAM rnnoise v0.1.1 examples/rnnoise_demo.c (unmodified, from
`git archive v0.1.1`) and running:  rnnoise_demo input.pcm golden.pcm
"""
import math, random, struct, sys

SR = 48000
N = 2 * SR
rnd = random.Random(20261021)

def resonator(freq, bw):
    r = math.exp(-math.pi * bw / SR)
    a1 = -2 * r * math.cos(2 * math.pi * freq / SR)
    a2 = r * r
    return a1, a2

formants = [resonator(f, b) for f, b in ((700, 110), (1220, 120), (2600, 160))]
fstate = [[0.0, 0.0] for _ in formants]
phase = 0.0
b = [0.0] * 3  # pink filter state
out = []
for n in range(N):
    t = n / SR
    f0 = 165 + 55 * math.sin(2 * math.pi * 0.7 * t)
    phase += f0 / SR
    pulse = 1.0 if phase >= 1.0 else 0.0
    if phase >= 1.0:
        phase -= 1.0
    s = pulse
    y = 0.0
    for i, (a1, a2) in enumerate(formants):
        st = fstate[i]
        v = s - a1 * st[0] - a2 * st[1]
        st[1], st[0] = st[0], v
        y += v
    env = max(0.0, math.sin(2 * math.pi * 2.0 * t)) ** 0.7  # 4 syllables/s
    if 0.9 < t < 1.2:
        env = 0.0  # pause
    speech = 900.0 * y * env
    w = rnd.uniform(-1, 1)
    b[0] = 0.99765 * b[0] + w * 0.0990460
    b[1] = 0.96300 * b[1] + w * 0.2965164
    b[2] = 0.57000 * b[2] + w * 1.0526913
    pink = b[0] + b[1] + b[2] + w * 0.1848
    noise = 1500.0 * pink + 300.0 * math.sin(2 * math.pi * 50 * t)
    v = int(round(speech + noise))
    out.append(max(-32768, min(32767, v)))

with open(sys.argv[1], "wb") as f:
    f.write(struct.pack("<%dh" % len(out), *out))
