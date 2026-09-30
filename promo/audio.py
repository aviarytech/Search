"""The soundtrack: seven bars of the song, cut on a downbeat, and every UI
sound placed so its loudest moment lands on the event it belongs to.

    python3 audio.py CACHE OUT.wav

CACHE holds the Mixkit files, fetched by build.sh (they are not ours to
redistribute, so they are not in the repository).
"""
import subprocess, sys, wave
import numpy as np
import imageio_ffmpeg

FF = imageio_ffmpeg.get_ffmpeg_exe()
SR = 48000
T = 14.0

cache, out = sys.argv[1], sys.argv[2]


def decode(path, mono=False):
    raw = subprocess.run([FF, "-loglevel", "error", "-i", path, "-f", "f32le", "-ac", "1" if mono else "2", "-ar", str(SR), "-"],
                         capture_output=True, check=True).stdout
    x = np.frombuffer(raw, np.float32)
    return x if mono else x.reshape(-1, 2)


# --- the beat grid -----------------------------------------------------------
song = decode(f"{cache}/song.mp3")
mono = song.mean(1)
hop, n = 256, 2048
frames = np.lib.stride_tricks.sliding_window_view(mono, n)[::hop] * np.hanning(n)
spec = np.log1p(20 * np.abs(np.fft.rfft(frames, axis=1)))
flux = np.maximum(0, np.diff(spec, axis=0)).sum(1)
fps = SR / hop
env = flux - np.convolve(flux, np.ones(16) / 16, "same")
env = np.maximum(env, 0)
# The period, measured by lining the onsets up with themselves 32, 48 and 64
# beats later: a long lag gives a precise one, where a one-beat lag is only as
# fine as a frame of the envelope.
hop2 = 64
fine = np.convolve(np.abs(np.diff(np.abs(mono))), np.ones(hop2), "valid")[::hop2]
ffps = SR / hop2
a0, L = int(40 * ffps), int(40 * ffps)
ref = fine[a0:a0 + L] - fine[a0:a0 + L].mean()
periods = []
for beats in (32, 48, 64):
    lags = np.arange(int((beats * 0.5 - 0.1) * ffps), int((beats * 0.5 + 0.1) * ffps))
    c = [np.dot(ref, fine[a0 + l:a0 + l + L] - fine[a0 + l:a0 + l + L].mean()) for l in lags]
    i = int(np.argmax(c)); y0, y1, y2 = c[i - 1], c[i], c[i + 1]
    periods.append((lags[i] + 0.5 * (y0 - y2) / (y0 - 2 * y1 + y2)) / ffps / beats)
period = float(np.median(periods))
print(f"tempo {60 / period:.3f} BPM")

# The drop: where the kick comes in after the breakdown, near 40 s. Found as
# the sharpest rise in low-band energy, then snapped to the kick's own onset.
low = np.abs(np.fft.rfft(frames, axis=1))[:, np.fft.rfftfreq(n, 1 / SR) < 150].sum(1)
t_frames = np.arange(len(low)) / fps
window = (t_frames > 38) & (t_frames < 42)
rise = np.diff(low, prepend=low[0])
guess = t_frames[window][np.argmax(rise[window])]
# The attack of each kick over the seven bars: where 1 ms loudness first
# jumps to three times the 10 ms before it. The median lands the grid on the
# attacks, which is where the ear hears the beat.
def attack(near):
    a = int((near - 0.08) * SR)
    seg = mono[a:a + int(0.16 * SR)]
    rms = np.sqrt(np.convolve(seg ** 2, np.ones(48) / 48, "same"))
    for i in range(480, len(rms)):
        if rms[i] > 3 * rms[i - 480:i - 48].mean() and rms[i] > 0.08:
            return (a + i) / SR - near
    return None
found = [attack(guess + k * period) for k in range(28)]
offset = float(np.median([o for o in found if o is not None]))
onset = guess + offset
print(f"downbeat at {onset:.4f} s")

# Seven bars, stretched by a hair so 28 beats last exactly 14 s.
start = int(onset * SR)
length = int(round(28 * period * SR))
bars = song[start:start + length]
stretch = len(bars) / (T * SR)
idx = np.clip(np.arange(int(T * SR)) * stretch, 0, len(bars) - 1)
music = np.stack([np.interp(idx, np.arange(len(bars)), bars[:, c]) for c in (0, 1)], 1)
# A 10 ms fade at each end: the seam where the loop meets itself.
f = int(0.010 * SR)
ramp = np.linspace(0, 1, f)[:, None]
music[:f] *= ramp
music[-f:] *= ramp[::-1]
music *= 0.72

# --- the UI sounds -------------------------------------------------------------
SOUNDS = {  # file, gain
    "click": ("click.mp3", 0.55),
    "release": ("click.mp3", 0.25),
    "switch": ("switch.mp3", 0.5),
    "check": ("check.mp3", 1.2),
    "key": ("key.mp3", 2.6),
    "enter": ("key.mp3", 3.6),
    "pop": ("pop.mp3", 0.7),
}
EVENTS = [
    (0.5, "click"), (2.02, "check"), (3.5, "click"), (4.5, "click"), (5.0, "click"), (5.5, "release"),
    (6.5, "click"), (7.5, "release"), (8.5, "switch"), (9.5, "click"),
    (12.0, "key"), (12.5, "key"), (12.625, "key"), (12.75, "key"), (13.0, "enter"), (13.05, "pop"),
]
fx = np.zeros_like(music)
for when, name in EVENTS:
    file, gain = SOUNDS[name]
    s = decode(f"{cache}/{file}")
    level = np.convolve(np.abs(s.mean(1)), np.ones(64) / 64, "same")
    peak = np.argmax(level)                      # the sound's measured peak...
    at = int(round(when * SR)) - peak        # ...placed on the event
    for k in (-1, 0, 1):                     # a tail past the end wraps round
        lo = at + k * int(T * SR)
        a, b = max(lo, 0), min(lo + len(s), len(fx))
        if a < b:
            fx[a:b] += gain * s[a - lo:b - lo]
    print(f"{name:8s} at {when:6.3f}s  peak {peak / SR * 1000:5.1f} ms into the file")

mix = music + fx
mix /= max(1.0, np.abs(mix).max() / 0.95)
with wave.open(out, "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((mix * 32767).astype("<i2").tobytes())
print("wrote", out)
