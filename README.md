# AliasProbe

**Proving ultrasonic ranging beyond iPhone hardware limits**

## The Breakthrough

iPhones sample audio at 48 kHz, imposing a hard Nyquist ceiling at 24 kHz. Conventional wisdom says this caps ultrasonic ranging resolution to what fits in the 0-24 kHz band. AliasProbe proves otherwise.

When the iPhone speaker plays a 16-20 kHz chirp, its inherent nonlinearity generates a 2nd harmonic at 32-40 kHz — frequencies above Nyquist that fold back into the recording as an 8-16 kHz alias (|48-32|=16, |48-40|=8 kHz). This alias is not noise; it carries real range information from the same physical reflections, just encoded in a reversed sweep direction (16→8 kHz instead of 16→20 kHz).

By detecting this alias, verifying its sweep direction matches the predicted harmonic structure, and stitching its correlation with the fundamental's, we recover spectral content the hardware was never designed to capture. The result: 1.5x ranging resolution improvement from a signal that wasn't supposed to exist, using nothing but the stock iPhone speaker and microphone.

No extra hardware. No jailbreak. Just physics the ADC couldn't suppress.

## What the App Tests

Three experiments run automatically after calibration:

1. **Alias Detection** — Measures alias power (8-16 kHz) during chirp vs guard intervals. If alias SNR > 3 dB, speaker nonlinearity is confirmed.

2. **Range Coherence** — Verifies the alias encodes real spatial information by checking its sweep direction. A true nonlinear alias from a 16→20 kHz fundamental must sweep 16→8 kHz (not 8→16 kHz). The direction ratio between correct and reversed references proves harmonic origin.

3. **Resolution Improvement** — Stitches fundamental (16-20 kHz) and alias (8-16 kHz) matched filter outputs, measuring -3 dB peak width before and after. A ratio > 1.0x proves the alias adds real resolving power.

## Usage

1. Open the app, tap **Calibrate** (no reflector nearby)
2. Place a flat reflector (iPad, book, wall) ~30 cm away
3. Tap **Run Probe**
4. All three tests should show green

## Build

Open `AliasProbe/AliasProbe.xcodeproj` in Xcode. Requires iOS 16+, tested on iPhone. Must run on a physical device (simulator has no speaker/mic).
