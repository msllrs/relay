#!/usr/bin/env python3
"""Generate Relay's start/stop recording sound themes.

Each theme is a pair: <theme>-start.wav / <theme>-stop.wav in
Relay/Resources/Sounds. All sounds are short (<400ms), subtle
(peak <= 0.24), mono 48kHz 16-bit.

Run from the repo root: python3 Scripts/generate-sounds.py
"""
import numpy as np
import wave
import os

SR = 48000
OUT = "Relay/Resources/Sounds"


def env(n, attack_s, release_start_s, k=4.5):
    e = np.ones(n)
    a = max(1, int(attack_s * SR))
    e[:a] = np.linspace(0, 1, a) ** 2
    r = int(release_start_s * SR)
    e[r:] = np.exp(-k * np.linspace(0, 1, n - r))
    return e


def glide_phase(f0, f1, dur_glide, dur_total):
    n = int(dur_total * SR)
    t = np.arange(n) / SR
    ng = int(dur_glide * SR)
    freq = np.full(n, f1, dtype=float)
    ease = (1 - np.cos(np.pi * np.linspace(0, 1, ng))) / 2
    freq[:ng] = f0 + (f1 - f0) * ease
    return t, 2 * np.pi * np.cumsum(freq) / SR


def detuned(phase, cents):
    return np.sin(phase * (2 ** (cents / 1200)))


def write(name, sig, peak):
    sig = sig / np.max(np.abs(sig)) * peak
    data = (sig * 32767).astype(np.int16)
    with wave.open(f"{OUT}/{name}.wav", "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    print(f"{name}: {len(sig)/SR*1000:.0f}ms peak={peak}")


# 1. Pulse — somber low minor intervals, slow dark pulse (the moody default)
def pulse(start):
    f0, f1 = (146.83, 174.61) if start else (174.61, 130.81)
    dur = 0.30 if start else 0.26
    t, p = glide_phase(f0, f1, 0.16 if start else 0.13, dur)
    sig = np.sin(p) + 0.8 * detuned(p, -5) + 0.30 * np.sin(p / 2) + 0.07 * np.sin(2 * p)
    sig *= 1 + 0.08 * np.sin(2 * np.pi * 71 * t)
    sig *= env(len(sig), 0.014 if start else 0.010, 0.18 if start else 0.14)
    write(f"pulse-{'start' if start else 'stop'}", sig, 0.22 if start else 0.18)


# 2. Ember — even lower and warmer, long embers-dying decay
def ember(start):
    f0, f1 = (110.0, 130.81) if start else (130.81, 98.0)
    dur = 0.42 if start else 0.36
    t, p = glide_phase(f0, f1, 0.20 if start else 0.16, dur)
    sig = np.sin(p) + 0.7 * detuned(p, -4) + 0.35 * np.sin(p / 2)
    sig *= 1 + 0.06 * np.sin(2 * np.pi * 47 * t)
    sig *= env(len(sig), 0.020, 0.16, k=3.5)
    write(f"ember-{'start' if start else 'stop'}", sig, 0.20 if start else 0.16)


# 3. Signal — the brighter classic chirp, tamed: mid register, quick
def signal(start):
    f0, f1 = (261.63, 392.0) if start else (392.0, 261.63)
    dur = 0.18 if start else 0.16
    t, p = glide_phase(f0, f1, 0.09, dur)
    sig = np.sin(p) + 0.6 * detuned(p, 5) + 0.12 * np.sin(2 * p)
    sig *= 1 + 0.08 * np.sin(2 * np.pi * 173 * t)
    sig *= env(len(sig), 0.006, 0.11 if start else 0.10)
    write(f"signal-{'start' if start else 'stop'}", sig, 0.22 if start else 0.18)


# 4. Sonar — a single soft ping with a long airy tail
def sonar(start):
    f0 = 440.0 if start else 293.66
    dur = 0.35 if start else 0.30
    t, p = glide_phase(f0, f0 * 0.97, dur, dur)  # barely-perceptible droop
    sig = np.sin(p) + 0.08 * np.sin(2 * p)
    sig *= env(len(sig), 0.004, 0.04, k=5.0)
    write(f"sonar-{'start' if start else 'stop'}", sig, 0.20 if start else 0.16)


# 5. Drift — airy dyad swell with a whisper of breath, no melody
def drift(start):
    dur = 0.38 if start else 0.30
    n = int(dur * SR)
    t = np.arange(n) / SR
    fa, fb = (146.83, 220.0) if start else (130.81, 196.0)
    sig = np.sin(2 * np.pi * fa * t) + 0.6 * np.sin(2 * np.pi * fb * t + 0.5)
    breath = np.convolve(np.random.default_rng(7).standard_normal(n), np.hanning(400), "same")
    sig += 0.05 * breath / np.max(np.abs(breath))
    sig *= env(len(sig), 0.12 if start else 0.08, 0.15 if start else 0.12, k=4.0)
    write(f"drift-{'start' if start else 'stop'}", sig, 0.18 if start else 0.15)


# 6. Circuit — two tiny staccato blips, digital handshake
def circuit(start):
    freqs = (146.83, 220.0) if start else (220.0, 146.83)
    blip_dur, gap = 0.045, 0.055
    parts = []
    for f in freqs:
        n = int(blip_dur * SR)
        t = np.arange(n) / SR
        b = np.sin(2 * np.pi * f * t) + 0.15 * np.sin(2 * np.pi * 2 * f * t)
        b *= env(n, 0.002, 0.008, k=7.0)
        parts.append(b)
        parts.append(np.zeros(int(gap * SR)))
    sig = np.concatenate(parts[:-1])
    write(f"circuit-{'start' if start else 'stop'}", sig, 0.24 if start else 0.20)


# 7. Hollow — odd harmonics, woody and cavernous
def hollow(start):
    f0, f1 = (98.0, 116.54) if start else (116.54, 87.31)
    dur = 0.32 if start else 0.28
    t, p = glide_phase(f0, f1, 0.14 if start else 0.12, dur)
    sig = np.sin(p) + 0.33 * np.sin(3 * p) + 0.18 * np.sin(5 * p)
    sig *= env(len(sig), 0.012, 0.14, k=4.0)
    write(f"hollow-{'start' if start else 'stop'}", sig, 0.20 if start else 0.16)


# 8. Glass — inharmonic bell strike, short glassy tick
def glass(start):
    f0 = 329.63 if start else 246.94
    dur = 0.26 if start else 0.22
    n = int(dur * SR)
    t = np.arange(n) / SR
    sig = np.zeros(n)
    for ratio, amp, decay in [(1.0, 1.0, 6), (2.76, 0.35, 9), (5.40, 0.15, 13), (8.93, 0.05, 18)]:
        sig += amp * np.sin(2 * np.pi * f0 * ratio * t) * np.exp(-decay * t)
    a = int(0.002 * SR)
    sig[:a] *= np.linspace(0, 1, a)
    write(f"glass-{'start' if start else 'stop'}", sig, 0.22 if start else 0.18)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for theme in (pulse, ember, signal, sonar, drift, circuit, hollow, glass):
        theme(True)
        theme(False)
