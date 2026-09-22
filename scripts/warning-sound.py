#!/usr/bin/env python3
"""Generate Onward's original warning sounds and quiet time cues.

All synthesis uses the Python standard library, with no external samples.
Run with --check to validate the existing assets without writing or playing audio.
"""

import argparse
import hashlib
import math
from pathlib import Path
import random
import struct
import wave


RATE = 44100
DEFAULT_SHA256 = "17138ff0d96151475b9b3a959aeddb44d88ae89cab9dd0a562743b20b1e0166e"


def generate(destination: Path) -> None:
    # Preserve the original Low warning synthesis and its exact PCM bytes.
    rate = 44100
    samples = [0.0] * int(rate * 0.94)
    # Two falling, slightly rough pulses: the second is lower and longer.
    for start, duration, frequency, end_frequency, gain in [
        (0.02, 0.28, 245.0, 185.0, 0.86),
        (0.39, 0.47, 185.0, 130.0, 1.0),
    ]:
        for index in range(int(duration * rate)):
            t = index / rate
            phase = 2 * math.pi * (frequency * t + (end_frequency - frequency) * t * t / (2 * duration))
            attack = math.sin(min(t / 0.018, 1.0) * math.pi / 2) ** 2
            release = math.sin(min((duration - t) / 0.085, 1.0) * math.pi / 2) ** 2
            envelope = attack * release * (0.9 + 0.1 * math.cos(2 * math.pi * 6 * t))
            tone = (math.sin(phase) + 0.36 * math.sin(2 * phase)
                    + 0.20 * math.sin(3 * phase) + 0.09 * math.sin(5 * phase)
                    + 0.18 * math.sin(1.05946 * phase))
            samples[int(start * rate) + index] += gain * envelope * tone
    scale = 0.72 / max(abs(sample) for sample in samples)
    frames = b"".join(struct.pack("<h", round(sample * scale * 32767)) for sample in samples)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(destination), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(rate)
        output.writeframes(frames)


def canvas(duration: float) -> list[float]:
    return [0.0] * round(RATE * duration)


def mix(samples, start, duration, oscillator, *, attack=0.008, release=0.04, gain=1.0):
    """Apply a smooth raised-sine envelope to each independently phased voice."""
    offset = round(start * RATE)
    count = round(duration * RATE)
    assert offset >= 0 and offset + count <= len(samples)
    for index in range(count):
        t = index / RATE
        fade_in = math.sin(min(t / attack, 1.0) * math.pi / 2) ** 2
        fade_out = math.sin(min((duration - t) / release, 1.0) * math.pi / 2) ** 2
        samples[offset + index] += gain * fade_in * fade_out * oscillator(t)


def tone(start, end=None, duration=1.0, partials=((1.0, 1.0),), decay=0.0, tremolo=0.0):
    end = start if end is None else end

    def oscillator(t):
        phase = 2 * math.pi * (start * t + (end - start) * t * t / (2 * duration))
        amplitude = math.exp(-decay * t)
        if tremolo:
            amplitude *= 0.83 + 0.17 * math.cos(2 * math.pi * tremolo * t)
        return amplitude * sum(gain * math.sin(multiplier * phase) for multiplier, gain in partials)

    return oscillator


def soft_noise(seed, cutoff):
    """Deterministic low-pass noise; no sharp white-noise transients."""
    rng = random.Random(seed)
    alpha = 1 - math.exp(-2 * math.pi * cutoff / RATE)
    filtered = 0.0

    def oscillator(_):
        nonlocal filtered
        filtered += alpha * (rng.random() * 2 - 1 - filtered)
        return filtered

    return oscillator


def write_sound(destination, samples, *, rms_target, peak_limit):
    peak = max(abs(sample) for sample in samples)
    active = [sample for sample in samples if abs(sample) > peak * 0.02]
    active_rms = math.sqrt(sum(sample * sample for sample in active) / len(active))
    # RMS targets compensate for bright versus bass-heavy timbres. The peak cap
    # takes priority over loudness matching, so percussive sounds remain gentle.
    scale = min(rms_target / active_rms, peak_limit / peak)
    frames = b"".join(struct.pack("<h", round(sample * scale * 32767)) for sample in samples)
    with wave.open(str(destination), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(frames)


def warning_sounds():
    sounds = {}

    # A compact three-note refusal, brighter and more staccato than Low warning.
    samples = canvas(0.78)
    for start, frequency, duration in [(0.02, 620, 0.14), (0.21, 465, 0.14), (0.41, 310, 0.29)]:
        mix(samples, start, duration,
            tone(frequency, frequency * 0.93, duration, ((1, 1), (2, 0.21), (3, 0.13), (1.07, 0.12))),
            attack=0.009, release=0.045)
    sounds["error"] = (samples, 0.26)

    # Alternating high/low alarm bursts with a clipped rhythm, not a rising chime.
    samples = canvas(0.88)
    for start, frequency in [(0.02, 740), (0.22, 555), (0.42, 740), (0.62, 440)]:
        mix(samples, start, 0.16, tone(frequency, partials=((1, 1), (3, 0.21), (5, 0.07))),
            attack=0.012, release=0.024)
    sounds["alarm"] = (samples, 0.23)

    # Three rounded bass pulses. Upper harmonics keep them audible on laptop speakers.
    samples = canvas(0.92)
    for start, gain in [(0.02, 0.86), (0.30, 1.0), (0.58, 0.92)]:
        mix(samples, start, 0.24, tone(115, 94, 0.24, ((1, 1), (2, 0.48), (3, 0.21)), decay=2),
            attack=0.035, release=0.10, gain=gain)
    sounds["pulse"] = (samples, 0.32)

    # Three spaced, gently decaying pings with falling pitch.
    samples = canvas(1.28)
    for start, frequency in [(0.02, 930), (0.40, 780), (0.78, 650)]:
        mix(samples, start, 0.42, tone(frequency, partials=((1, 1), (2, 0.08)), decay=8),
            attack=0.007, release=0.08)
    sounds["radar"] = (samples, 0.23)

    # A woody double knock: short resonant modes with a quiet, filtered impact.
    samples = canvas(0.54)
    for index, start in enumerate([0.02, 0.26]):
        noise = soft_noise(4100 + index, 1100)
        modes = tone(180, partials=((1, 1), (2.07, 0.62), (3.13, 0.28)), decay=20)
        mix(samples, start, 0.20, lambda t, n=noise, m=modes: m(t) + 0.55 * n(t) * math.exp(-55 * t),
            attack=0.003, release=0.06, gain=1.0 if index == 0 else 0.88)
    sounds["knock"] = (samples, 0.29)

    # One sustained raspy buzz, with a falling tail and shallow amplitude roughness.
    samples = canvas(0.80)
    partials = tuple((n, 1 / n) for n in [1, 2, 3, 4, 5, 7, 9, 11])
    mix(samples, 0.02, 0.70, tone(165, 135, 0.70, partials, tremolo=27), attack=0.016, release=0.11)
    sounds["buzzer"] = (samples, 0.27)

    # A single lower, inharmonic bell. The high modes decay before the body.
    samples = canvas(1.42)

    def bell(t):
        return sum(gain * math.exp(-decay * t) * math.sin(2 * math.pi * frequency * t)
                   for frequency, gain, decay in [(470, 1, 3.5), (1297, 0.31, 6), (1913, 0.12, 9), (2552, 0.04, 12)])

    mix(samples, 0.02, 1.32, bell, attack=0.008, release=0.20)
    sounds["bell"] = (samples, 0.25)

    # A continuous pair of falling wails, with phase continuity between sweeps.
    samples = canvas(1.32)

    def siren(t):
        phase = 2 * math.pi * (280 * t - 30 * t * t + 100 * 0.62 / (2 * math.pi) * math.sin(2 * math.pi * t / 0.62))
        return math.sin(phase) + 0.24 * math.sin(2 * phase) + 0.09 * math.sin(3 * phase)

    mix(samples, 0.02, 1.20, siren, attack=0.025, release=0.16)
    sounds["siren"] = (samples, 0.25)

    # A small digital downward chirr: three quick sweeps, with a soft final tail.
    samples = canvas(0.48)
    for start, high, low, duration in [(0.02, 1800, 1000, 0.075), (0.14, 1450, 800, 0.075), (0.26, 1150, 620, 0.13)]:
        mix(samples, start, duration, tone(high, low, duration, ((1, 1), (2, 0.05))),
            attack=0.006, release=0.035)
    sounds["chirp"] = (samples, 0.21)
    return sounds


def time_sounds():
    sounds = {}

    # A rounded clock tick, with no hard impulse or high-frequency click.
    samples = canvas(0.075)
    mix(samples, 0.005, 0.050, tone(1050, 850, 0.05, decay=45), attack=0.003, release=0.018)
    sounds["tick"] = (samples, 0.16)

    # One warm wooden tap, softer and smaller than the double-knock warning.
    samples = canvas(0.13)
    noise = soft_noise(7201, 800)
    body = tone(230, partials=((1, 1), (2.18, 0.45)), decay=29)
    mix(samples, 0.005, 0.105, lambda t: body(t) + 0.20 * noise(t) * math.exp(-70 * t),
        attack=0.003, release=0.035)
    sounds["wood"] = (samples, 0.16)

    # A soft water-drop pitch bend; rounded rather than a bright notification ping.
    samples = canvas(0.22)
    mix(samples, 0.008, 0.185, tone(510, 230, 0.185, ((1, 1), (2, 0.10)), decay=13),
        attack=0.009, release=0.06)
    sounds["drop"] = (samples, 0.15)

    # A short, dull fingertip tap with a low body and no high transient.
    samples = canvas(0.065)
    mix(samples, 0.004, 0.042, tone(260, partials=((1, 1), (2.35, 0.24)), decay=58),
        attack=0.003, release=0.020)
    sounds["tap"] = (samples, 0.16)

    # A tiny soft breath of low-pass noise, with a broad feathered envelope.
    samples = canvas(0.19)
    mix(samples, 0.009, 0.155, soft_noise(8803, 650), attack=0.035, release=0.070)
    sounds["air"] = (samples, 0.13)
    return sounds


def validate(directory):
    files = [directory / "OnwardWarning.wav"]
    files += [directory / f"OnwardWarning-{name}.wav" for name in warning_sounds()]
    files += [directory / f"OnwardTime-{name}.wav" for name in time_sounds()]
    assert hashlib.sha256(files[0].read_bytes()).hexdigest() == DEFAULT_SHA256, "Low warning changed"
    hashes = set()
    for path in files:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        assert digest not in hashes, f"Duplicate audio: {path.name}"
        hashes.add(digest)
        with wave.open(str(path), "rb") as source:
            assert (source.getnchannels(), source.getsampwidth(), source.getframerate(), source.getcomptype()) == (1, 2, RATE, "NONE")
            samples = [sample[0] / 32768 for sample in struct.iter_unpack("<h", source.readframes(source.getnframes()))]
        duration = len(samples) / RATE
        is_time = path.name.startswith("OnwardTime-")
        assert (0.035 <= duration <= 0.25) if is_time else (0.4 <= duration <= 1.6)
        peak = max(abs(sample) for sample in samples)
        assert 0.1 < peak <= (0.4 if is_time else 0.721)
        assert all(sample == 0 for sample in samples[:88] + samples[-88:]), f"Non-silent endpoints: {path.name}"
        rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples))
        assert rms > (0.015 if is_time else 0.04), f"Unexpectedly quiet: {path.name}"
        print(f"{path.stem}: {duration:.3f}s, peak {peak:.3f}, RMS {rms:.3f}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate existing assets without writing audio")
    args = parser.parse_args()
    directory = Path(__file__).resolve().parent.parent / "Resources"
    if not args.check:
        generate(directory / "OnwardWarning.wav")
        for name, (samples, target) in warning_sounds().items():
            write_sound(directory / f"OnwardWarning-{name}.wav", samples, rms_target=target, peak_limit=0.70)
        for name, (samples, target) in time_sounds().items():
            write_sound(directory / f"OnwardTime-{name}.wav", samples, rms_target=target, peak_limit=0.38)
    validate(directory)
