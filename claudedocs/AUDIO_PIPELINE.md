# Micify Audio Pipeline — Technical Reference

## Overview

Micify captures raw PCM audio from the device microphone, processes it through a
multi-layer hybrid pipeline, and feeds it to the active audio output in real time.
All processing runs on-device with no cloud calls in the relay path.

## Pipeline Architecture

```
Microphone (hardware)
    │
    ▼
AudioRecord (Android)
    │  audioSource = VOICE_COMMUNICATION
    │  sampleRate  = 16000 Hz
    │  encoding    = PCM_16BIT mono
    │
    ├─► Native AcousticEchoCanceler  (hardware DSP — AecChannel.kt)
    ├─► Native NoiseSuppressor       (hardware DSP — AecChannel.kt)
    │
    ▼
record package → startStream() → Stream<Uint8List>
    │
    ▼
Dart processing loop (_processAudio)
    │
    ├─► High-pass IIR filter         (Butterworth, cutoff 80–300Hz configurable)
    ├─► Low-pass IIR filter          (Butterworth, fixed 8000Hz)
    ├─► LMS adaptive notch filter    (64-tap, μ=0.00005 — DISABLED, see notes)
    ├─► Scalar gain amplifier        (1.0×–10.0×, user-controlled)
    ├─► Soft limiter                 (tanh-based, configurable threshold 30–100%)
    ├─► Peak detector                (volume meter + feedback detection)
    │
    ▼
flutter_pcm_sound → feed(PcmArrayInt16)
    │  feedThreshold = 2048 samples (~128ms buffer)
    │
    ▼
Active audio output (Bluetooth / AUX / built-in speaker)
```

## Layer Details

### Layer 1 — Native AcousticEchoCanceler (Kotlin)

**File:** `android/app/src/main/kotlin/com/vel/micify/AecChannel.kt`
**Channel:** `com.vel.micify/aec`

Attaches Android's hardware DSP directly to the `AudioRecord` session.
- `AcousticEchoCanceler` — subtracts speaker output from mic input using a
  reference signal. Equivalent to what Android uses during phone calls. Instant
  convergence, handles multiple frequencies simultaneously.
- `NoiseSuppressor` — hardware-level background noise suppression.
- `AutomaticGainControl` — attached but disabled; gain is controlled in Dart.

Gracefully degrades: if hardware AEC is unavailable on the device, the catch block
silences the error and Dart-side layers continue running.

### Layer 2 — High-pass IIR Filter (Dart)

**Cutoff:** 80–300Hz (user-configurable via Low-cut slider)
**Type:** 2nd order Butterworth

Cuts fan noise, AC hum, rumble, and low-frequency ambient noise. Coefficients are
recomputed dynamically using the bilinear transform when the user adjusts the slider.
Filter state persists between chunks; reset on stop.

### Layer 3 — Low-pass IIR Filter (Dart)

**Cutoff:** 8000Hz (fixed)
**Type:** 2nd order Butterworth

Cuts high-frequency hiss above the voice range. Human speech intelligibility is
fully contained within 80Hz–8000Hz. Fixed because there is no use case for relaying
frequencies above 8kHz in voice amplification.

### Layer 4 — LMS Adaptive Notch Filter (Dart) — DISABLED BY DEFAULT

**Order:** 64 taps
**Step size (μ):** 0.00005
**Status:** `_adaptiveNotchEnabled = false`

Designed to track and cancel residual narrowband feedback that passes hardware AEC.
**Disabled by default** because at any μ fast enough to converge on feedback, the filter
also adapts to voice patterns (vowels, sustained notes) and cancels them — voice relay
breaks. LMS is only safe for narrowband stationary signals; voice is wideband and
non-stationary.

Hardware AEC (Layer 1) is the correct and primary feedback cancellation path. This layer
remains in code for potential future use (e.g., gated on a confirmed feedback tone
frequency detected separately).

### Layer 5 — Scalar Gain Amplifier (Dart)

**Range:** 1.0×–10.0× (user-controlled slider)
**Default:** 1.5×

Applied after all filtering so gain only amplifies the clean voice signal.

### Layer 6 — Soft Limiter (Dart)

**Threshold:** 30–100% of full scale (user-controlled)
**Algorithm:** Tanh-based soft knee

Prevents harsh clipping distortion at high gain settings. The tanh curve provides
smooth saturation rather than hard clipping, preserving voice naturalness near the
ceiling.

### Layer 7 — Feedback Detection (Dart)

Monitors peak output level per chunk. If output stays at ≥95% of full scale for
8 consecutive chunks (~200ms), auto-reduces gain by 20% and shows a warning banner.
This acts as a safety net for the LMS filter during its convergence window.

## Configuration Parameters

| Parameter | Range | Default | Control |
|---|---|---|---|
| Gain | 1.0×–10.0× | 1.5× | Slider |
| Low-cut frequency | 50–300 Hz | 80 Hz | Slider |
| Max output threshold | 30–100% | 90% | Slider |
| Echo cancellation | On/Off | On | Toggle |
| Noise suppression | On/Off | On | Toggle |
| Adaptive notch | Always on | — | Internal |

## Presets

| Preset | Gain | Low-cut | Max volume |
|---|---|---|---|
| Gentle | 1.5× | 80 Hz | 50% |
| Quiet room | 2.0× | 80 Hz | 90% |
| Classroom | 3.5× | 100 Hz | 90% |
| Outdoor | 6.0× | 120 Hz | 90% |
| Large hall | 8.0× | 150 Hz | 90% |

## Sample Rate Decision

16 kHz mono PCM-16LE. Rationale:
- Nyquist limit covers full voice range (8kHz max frequency)
- Half the bandwidth of 44.1kHz — smaller chunks, lower latency
- Matches `VOICE_COMMUNICATION` audio source optimal operating range

## Latency Budget

| Stage | Latency |
|---|---|
| AudioRecord buffer | ~10ms |
| Dart processing per chunk | <2ms |
| flutter_pcm_sound buffer (2048 samples) | ~128ms |
| Bluetooth codec (device dependent) | 40–200ms |
| **Total (wired AUX)** | **~20–30ms** |
| **Total (Bluetooth)** | **~150–300ms** |

Bluetooth latency is codec-dependent and outside Micify's control. Wired AUX
consistently meets the <50ms target.

## Platform Channel

**Name:** `com.vel.micify/aec`

| Method | Arguments | Returns |
|---|---|---|
| `attach` | `audioSessionId: int` | `{aecAttached: bool, nsAttached: bool}` |
| `release` | — | `null` |
| `isAvailable` | — | `bool` |
