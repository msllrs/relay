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


# --- Blip family -------------------------------------------------------------

def _blips(name, start, freqs, blip_dur=0.045, gap=0.055, amps=None, peak_start=0.24, peak_stop=0.20):
    amps = amps or [1.0] * len(freqs)
    parts = []
    for f, a in zip(freqs, amps):
        n = int(blip_dur * SR)
        t = np.arange(n) / SR
        b = a * (np.sin(2 * np.pi * f * t) + 0.15 * np.sin(2 * np.pi * 2 * f * t))
        b *= env(n, 0.002, 0.008, k=7.0)
        parts.append(b)
        parts.append(np.zeros(int(gap * SR)))
    sig = np.concatenate(parts[:-1])
    write(f"{name}-{'start' if start else 'stop'}", sig, peak_start if start else peak_stop)


# 1. Circuit — two tiny staccato blips, digital handshake (default)
def circuit(start):
    freqs = (146.83, 220.0) if start else (220.0, 146.83)
    _blips("circuit", start, freqs)


# 2. Relay — three-blip data burst, rising in, falling out
def relay(start):
    freqs = (146.83, 174.61, 220.0) if start else (220.0, 174.61, 146.83)
    _blips("relay", start, freqs, blip_dur=0.032, gap=0.042)


# 3. Breaker — one low chunky blip with a quiet echo
def breaker(start):
    f = 110.0 if start else 98.0
    _blips("breaker", start, (f, f), blip_dur=0.06, gap=0.09, amps=[1.0, 0.45],
           peak_start=0.24, peak_stop=0.20)


# --- Somber glide family ------------------------------------------------------

def _glide_pad(name, start, f0, f1, dur, dur_glide, ring_hz, attack, release_start,
               k=4.5, sub=0.30, peak_start=0.22, peak_stop=0.18):
    t, p = glide_phase(f0, f1, dur_glide, dur)
    sig = np.sin(p) + 0.8 * detuned(p, -5) + sub * np.sin(p / 2) + 0.07 * np.sin(2 * p)
    sig *= 1 + 0.08 * np.sin(2 * np.pi * ring_hz * t)
    sig *= env(len(sig), attack, release_start, k=k)
    write(f"{name}-{'start' if start else 'stop'}", sig, peak_start if start else peak_stop)


# 4. Pulse — somber minor-third rise/fall, slow dark pulse
def pulse(start):
    f0, f1 = (146.83, 174.61) if start else (174.61, 130.81)
    _glide_pad("pulse", start, f0, f1, 0.30 if start else 0.26,
               0.16 if start else 0.13, 71, 0.014 if start else 0.010,
               0.18 if start else 0.14)


# 5. Abyss — pulse a fifth lower, longer tail; the deep end
def abyss(start):
    f0, f1 = (110.0, 130.81) if start else (130.81, 98.0)
    _glide_pad("abyss", start, f0, f1, 0.36 if start else 0.32,
               0.18 if start else 0.15, 53, 0.018, 0.16, k=3.5, sub=0.38,
               peak_start=0.20, peak_stop=0.16)


# 6. Umbra — pulse with a barely-there semitone creep; the ominous one
def umbra(start):
    f0, f1 = (146.83, 155.56) if start else (155.56, 130.81)
    _glide_pad("umbra", start, f0, f1, 0.34 if start else 0.30,
               0.22 if start else 0.18, 59, 0.016, 0.17, k=4.0,
               peak_start=0.20, peak_stop=0.16)


# --- Airy family --------------------------------------------------------------

def _air(name, start, fa, fb, dur, attack, release_start, breath, seed, peak_start, peak_stop):
    n = int(dur * SR)
    t = np.arange(n) / SR
    sig = np.sin(2 * np.pi * fa * t) + 0.6 * np.sin(2 * np.pi * fb * t + 0.5)
    noise = np.convolve(np.random.default_rng(seed).standard_normal(n), np.hanning(400), "same")
    sig += breath * noise / np.max(np.abs(noise))
    sig *= env(len(sig), attack, release_start, k=4.0)
    write(f"{name}-{'start' if start else 'stop'}", sig, peak_start if start else peak_stop)


# 7. Drift — airy dyad swell with a whisper of breath
def drift(start):
    fa, fb = (146.83, 220.0) if start else (130.81, 196.0)
    _air("drift", start, fa, fb, 0.38 if start else 0.30,
         0.12 if start else 0.08, 0.15 if start else 0.12, 0.05, 7, 0.18, 0.15)


# 8. Haze — drift sunk lower, breathier, slower swell
def haze(start):
    fa, fb = (110.0, 164.81) if start else (98.0, 146.83)
    _air("haze", start, fa, fb, 0.45 if start else 0.36,
         0.16 if start else 0.11, 0.18 if start else 0.14, 0.08, 11, 0.16, 0.13)


# --- Ambient family (soft taps with reverb tails, superwhisper-adjacent) -----

def _reverberate(dry, tail_s, mix, seed=3):
    """Convolve with a decaying-noise impulse response; output includes the tail."""
    ir_n = int(tail_s * SR)
    t = np.arange(ir_n) / SR
    ir = np.random.default_rng(seed).standard_normal(ir_n) * np.exp(-7 * t / tail_s)
    wet = np.convolve(dry, ir)
    wet = wet / (np.max(np.abs(wet)) + 1e-9)
    padded = np.concatenate([dry, np.zeros(len(wet) - len(dry))])
    return (1 - mix) * padded + mix * wet


def _tap(freq, dur=0.18):
    """A felt-soft tap: slightly inharmonic partials, fast decay."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    sig = (np.sin(2 * np.pi * freq * t) * np.exp(-9 * t / dur)
           + 0.20 * np.sin(2 * np.pi * 2.03 * freq * t) * np.exp(-14 * t / dur)
           + 0.08 * np.sin(2 * np.pi * 3.9 * freq * t) * np.exp(-20 * t / dur))
    a = int(0.006 * SR)
    sig[:a] *= np.linspace(0, 1, a)
    return sig


def _bed(n, freq=103.0, amp=0.15):
    """Quiet low drone under the tap, swelling in and fading with the tail."""
    t = np.arange(n) / SR
    drone = amp * np.sin(2 * np.pi * freq * t)
    a = int(0.08 * SR)
    e = np.exp(-3.0 * t / (n / SR))
    e[:a] *= np.linspace(0, 1, a)
    return drone * e


# 9. Felt — one soft piano-like tap in a small room
def felt(start):
    f = 523.25 if start else 261.63
    sig = _reverberate(_tap(f), tail_s=0.50, mix=0.40)
    sig += _bed(len(sig))
    write(f"felt-{'start' if start else 'stop'}", sig, 0.18 if start else 0.15)


# 10. Ripple — two gentle taps, rising in and settling out, watery tail
def ripple(start):
    f1, f2 = (392.0, 523.25) if start else (523.25, 329.63)
    gap = int(0.09 * SR)
    tap1, tap2 = _tap(f1), _tap(f2)
    dry = np.concatenate([tap1, np.zeros(max(0, gap + len(tap2) - len(tap1)))])
    dry[gap:gap + len(tap2)] += 0.8 * tap2
    sig = _reverberate(dry, tail_s=0.55, mix=0.50, seed=5)
    sig += _bed(len(sig))
    write(f"ripple-{'start' if start else 'stop'}", sig, 0.17 if start else 0.14)


# 11. Halo — the bed carries it; the tap is barely there, longest tail
def halo(start):
    f = 329.63 if start else 246.94
    sig = _reverberate(0.6 * _tap(f, dur=0.22), tail_s=0.70, mix=0.55, seed=9)
    sig += _bed(len(sig), amp=0.30)
    write(f"halo-{'start' if start else 'stop'}", sig, 0.15 if start else 0.13)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for theme in (circuit, relay, breaker, pulse, abyss, umbra, drift, haze, felt, ripple, halo):
        theme(True)
        theme(False)
