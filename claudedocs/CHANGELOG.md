# Micify Development Changelog

## Session — 2026-06-19 (continued — Kids mode, foreground service, distribution)

### Architecture — Kotlin Foreground Service
- Moved entire audio DSP from Dart to `MicRelayService.kt` (new Kotlin foreground service)
- Relay now survives screen lock — foreground notification with Stop action shown while active
- All IIR filters (high-pass, low-pass, bass shelf, mid peak, treble shelf) ported to Kotlin hot path
- Soft tanh limiter ported to Kotlin
- Platform channel `com.vel.micify/relay_service` added — Flutter sends control commands only
- `FOREGROUND_SERVICE_MICROPHONE` permission + `foregroundServiceType="microphone"` in manifest
- `MicRelayService.LocalBinder` pattern — `MainActivity` binds and receives level callbacks

### Features Added
- **EQ sliders** — Bass / Mid / Treble (±12 dB), Butterworth biquad IIR per Audio EQ Cookbook
- **Room presets** — Gentle / Quiet room / Classroom / Outdoor / Large hall (bakes gain + EQ + low-cut)
- **Mic source selector** — Built-in / Wired / Bluetooth pills; Bluetooth SCO managed in `AudioRouteChannel.kt`
- **Haptic feedback** — `HapticFeedback.mediumImpact()` on every Start / Stop
- **Volume key shortcut** — physical volume up/down toggles relay via `HardwareKeyboard.instance.addHandler`
- **Kids mode tab** — `NavigationBar` + `IndexedStack` tab switching; 2×3 voice effect grid
- **Voice effects** — Normal / Kid / Chipmunk / Adult / Monster / Robot via `AudioTrack.setPlaybackRate()`
- **Pitch/tempo live update** — `applySettings` propagates `pitchRate` to running `AudioTrack` without restart
- **Animated mic button** — pulse ring scales with volume level; inner button glows on active
- **Bar visualiser** — 20 bars with per-bar noise + exponential smoothing; shown in both tabs

### UI Redesign
- Bold dark gradient background (`#0D0D1A` → `#1A0D2E`)
- Accent colour `#7C4DFF` (deep purple) throughout
- Advanced settings collapsed under `ExpansionTile` by default
- Horizontal scrollable preset pills; horizontal mic source pills
- Immersive sticky mode (system bars hidden)

### Build Fix
- Removed duplicate `@override` annotation before `initState()` (caused parser confusion)
- Removed extra closing paren in `_buildRelayTab` — bracket mismatch introduced during iterative edits
- Universal APK (`flutter build apk --debug`) built successfully for Samsung M34 5G installation

### New Files
| File | Purpose |
|---|---|
| `android/app/src/main/kotlin/com/vel/micify/MicRelayService.kt` | Foreground service — full audio pipeline in Kotlin |
| `android/app/src/main/kotlin/com/vel/micify/AudioRouteChannel.kt` | Mic source selection, Bluetooth SCO control |

### Files Changed
| File | Change |
|---|---|
| `lib/main.dart` | Full rewrite — UI only, all DSP removed; Kids tab, voice effects, mic selector, haptics |
| `android/app/src/main/kotlin/com/vel/micify/MainActivity.kt` | Three MethodChannels; service binding; level callback |
| `android/app/src/main/AndroidManifest.xml` | Foreground service declaration + microphone type |

### Planning & Strategy Docs Updated
- `CLAUDE.md` — foreground service marked shipped in v1; ads strategy section added; versioning table updated with all milestones and status
- Distribution & Release Strategy section added to `CLAUDE.md`

---

## Session — 2026-06-19

### Project Bootstrap
- Created Flutter project with package ID `com.vel.micify`
- Defined target use cases: classroom teaching, school announcements, accessibility,
  tour guides, small worship events, speech practice, creators
- Established roadmap: v1 Relay → v1.1 AI Relay → v2 Practice → v3 Creator → v4 Polish
- Documented commercialization strategy: freemium, institutional licensing, grants

### Build System Fixes
- Replaced `mic_stream 0.7.2` (abandoned, Flutter v1 embedding) with `record 6.2.1`
- Replaced `sound_stream` (AGP 8.x incompatible) with `flutter_pcm_sound 3.3.3`
- Regenerated Android project via `flutter create` — migrated from Groovy DSL to
  Kotlin DSL (`.gradle.kts`) Gradle files
- Deleted conflicting old `.gradle` files that shadowed new KTS versions
- Upgraded AGP: 8.1.0 → 8.7.3 (via new KTS settings)
- Upgraded Gradle wrapper: 8.4 → 8.9 (required by AGP 8.7.3)
- Pinned NDK version to `27.0.12077973` (required by all three plugins)
- Set `minSdk = 23` (required by `record_android`)
- Added `kotlin.incremental=false` to `gradle.properties` — fixes Kotlin incremental
  compiler crash when source files span C: and D: drives (Windows-specific issue)

### Audio Pipeline — v1 Core
- Implemented live mic-to-speaker relay loop:
  `record.startStream()` → Dart gain loop → `flutter_pcm_sound.feed()`
- Sample rate: 16 kHz mono PCM-16LE
- Feed threshold: 2048 samples (~128ms buffer, reduced from 8000 for lower latency)
- Default gain: 1.5× (empirically determined as practical minimum for clean signal)

### Audio Quality Improvements
- Switched audio source to `VOICE_COMMUNICATION` — activates Android's full
  hardware AEC stack (same as phone calls)
- Set audio manager mode to `modeInCommunication`
- Enabled `echoCancel: true` and `noiseSuppress: true` in `RecordConfig`
- Implemented 2nd order Butterworth high-pass filter (cutoff configurable 50–300Hz)
  — eliminates fan noise, AC hum, rumble below voice range
- Implemented 2nd order Butterworth low-pass filter (fixed 8kHz)
  — eliminates hiss above voice range
- Implemented 64-tap LMS adaptive notch filter (μ=0.0005)
  — tracks and cancels residual feedback frequency in real time
- Implemented tanh-based soft limiter — prevents distortion at high gain
- Implemented native `AcousticEchoCanceler` + `NoiseSuppressor` Kotlin platform
  channel (`com.vel.micify/aec`) for hardware-level echo cancellation

### UI Features Added
- Live volume meter (input level bar, updates per chunk)
- Gain slider: 1.0×–10.0×, default 1.5×
- Low-cut frequency slider: 50–300Hz (controls high-pass filter cutoff live)
- Max volume slider: 30–100% (controls soft limiter threshold)
- Echo cancellation toggle (disabled while running — requires restart)
- Noise suppression toggle (disabled while running — requires restart)
- Presets: Gentle / Quiet room / Classroom / Outdoor / Large hall
- Feedback warning banner (auto-dismisses after 3 seconds)
- Screen keep-on via `wakelock_plus` while relay is active
- Immersive sticky UI mode (hides system bars)

### Packages Added
| Package | Version | Purpose |
|---|---|---|
| `record` | 6.2.1 | Mic capture, PCM stream |
| `flutter_pcm_sound` | 3.3.3 | PCM audio output |
| `permission_handler` | 11.3.1 | Runtime permissions |
| `wakelock_plus` | 1.4.0 | Keep screen on during relay |

### Android Permissions
- `RECORD_AUDIO` — microphone capture
- `BLUETOOTH` + `BLUETOOTH_ADMIN` — pre-Android 12 Bluetooth
- `BLUETOOTH_CONNECT` + `BLUETOOTH_SCAN` — Android 12+ Bluetooth

### Testing
- Verified relay loop on Pixel 6 emulator (API 33)
- Verified on Samsung Galaxy M34 5G (ARM64, Bluetooth speaker)
- Confirmed bandpass filter reduces fan noise at gain 1.0×
- Confirmed feedback detection triggers at sustained 95%+ output

### Bug Fix — LMS Filter Cancelling Voice

**Symptom:** Voice not relayed to speaker; feedback warning showing continuously on normal speech.

**Root cause:** The LMS adaptive notch filter (μ=0.0005) adapted fast enough to identify
repeating patterns in voice (vowels, sustained notes) and subtracted them from the output.
Voice-frequency components were treated as feedback — output dropped to near-zero. The
feedback detector saw sustained near-zero output and kept displaying the warning.

**Fixes applied:**
- `_adaptiveNotchEnabled = false` — LMS disabled by default; hardware AEC handles echo
- `_notchMu` reduced from 0.0005 → 0.00005 (10× slower adaptation for future re-enable)
- `_feedbackLevelThreshold` raised from 0.95 → 0.99 (only triggers on true clipping)
- `_feedbackChunkThreshold` raised from 8 → 20 chunks (~200ms → ~500ms sustained)
- Feedback condition changed from hardcoded 0.95 to use `_feedbackLevelThreshold`

**Why LMS fails for voice:** LMS is designed for narrowband stationary feedback (a fixed squeal).
Voice is wideband and non-stationary — it changes constantly. LMS cannot distinguish voice
from feedback at μ=0.0005. Hardware AEC with a reference signal is the correct approach for
echo/feedback in voice relay.

### Known Limitations (v1)
- Bluetooth latency: 150–300ms (codec-dependent, outside app control)
- Relay stops when app goes to background (foreground service planned for v4)
- Echo/feedback best controlled by speaker placement; software AEC helps but
  cannot fully replace physical separation in close-range setups
- LMS notch filter disabled by default — hardware AEC is the primary feedback path

### Files Changed
| File | Change |
|---|---|
| `lib/main.dart` | Full audio pipeline + UI implementation |
| `android/app/src/main/kotlin/com/vel/micify/MainActivity.kt` | Register AEC platform channel |
| `android/app/src/main/kotlin/com/vel/micify/AecChannel.kt` | New — native AEC/NS platform channel |
| `android/app/build.gradle.kts` | minSdk 23, NDK 27.0.12077973 |
| `android/settings.gradle.kts` | AGP 8.7.3, Kotlin 2.1.0 |
| `android/gradle/wrapper/gradle-wrapper.properties` | Gradle 8.9 |
| `android/gradle.properties` | kotlin.incremental=false |
| `android/app/src/main/AndroidManifest.xml` | All required permissions |
| `pubspec.yaml` | record, flutter_pcm_sound, permission_handler, wakelock_plus |
| `CLAUDE.md` | Audio backend decision log updated |
