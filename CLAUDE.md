# CLAUDE.md - Micify Project Guidelines

## Project Context
Micify is an open-source, ultra-low-latency real-time microphone amplification and live relay utility built with Flutter. Its primary purpose is to relay raw PCM audio from the device microphone to the currently active audio output (Bluetooth speaker, wired AUX, or built-in speaker) with the lowest possible latency. A scalar gain slider ships as a core v1 feature alongside the relay.

## Target Use Cases
Micify is designed for non-technical users in real-world amplification scenarios — no account, no setup, no PA system required.

| Scenario | Description |
|---|---|
| **Classroom teaching** | Teacher wears phone, mic relays voice to a Bluetooth speaker — replaces a PA system |
| **School announcements** | Hand phone to speaker, output booms through a portable speaker, zero configuration |
| **Accessibility** | Person holds phone near audio source, output goes to their Bluetooth earpiece as a personal amplifier |
| **Tour guides / coaching** | Outdoor use; portable speaker + phone replaces a dedicated mic/amp rig |
| **Small worship / events** | Low-budget amplification for small venues |
| **Children / speech practice** | Kids hear their own voice back, build confidence and projection |
| **Teenagers / creators** | Voice effects, clip sharing, freestyle sessions — creative expression |

### UX Implications
- **One-button operation** — UI must be near-zero learning curve; non-technical users hand the phone to anyone
- **No accounts ever** — no sign-up, no saved sessions; hard rule across all versions
- **Gain slider is core** — variable room acoustics make gain control essential, not optional
- **Battery efficiency** — continuous audio loop must be lightweight; outdoor/extended use is expected
- **Mode-based UX** — v2+ introduces selectable modes (Relay / Practice / Creator); each mode has its own UX personality appropriate to its audience

## Target Audiences

| Audience | Mode | Core need |
|---|---|---|
| Teachers / staff | Relay | Replace PA system, zero setup |
| Young children | Practice | Hear themselves, build confidence |
| Teenagers | Creator | Express, experiment, share |

## Roadmap

### v1 — Relay (current)
**Audience:** Teachers, staff, non-technical users
**Single screen, one-button operation.**
- Live mic → active output relay
- Gain slider (1×–10×)
- Runtime permissions (mic, Bluetooth)

### v1.1 — AI-enhanced Relay
**Audience:** Same as v1, quality upgrade
- **Noise suppression** — on-device TFLite model strips background noise from relay stream; no latency impact
- **Voice activity detection** — auto-mutes when no one is speaking (saves battery, prevents background bleed)
- **Adaptive gain** — ML model monitors ambient noise and adjusts gain automatically; manual slider remains as override

**Technical rule:** All v1.1 AI runs on-device only — no cloud calls in the real-time relay path.

**Open-source libraries for v1.1:**
| Library | Purpose | Integration | Licence |
|---|---|---|---|
| **RNNoise** | Neural noise suppression — replaces Android NS; preserves voice at low SNR | Kotlin JNI wrapper | BSD |
| **Silero VAD** | Voice activity detection — auto-mute during silence, saves battery | TFLite / ONNX Runtime | MIT |
| **WebRTC APM** | Full audio processing (AEC + NS + AGC) — same stack as Google Meet | Kotlin JNI wrapper | BSD |

Priority order: RNNoise first (biggest quality jump, simplest integration), then Silero VAD, then WebRTC APM if RNNoise + hardware AEC still leaves gaps.

### v2 — Practice + Voice Changer
**Audience:** Young children, students, school plays
**A second mode selectable from the home screen.**

Speech Practice:
- Record a 15–30s clip, instant playback so child hears themselves
- Loudness meter — visual bar turns green when they hit target volume
- Word/phrase card deck — word on screen, child reads aloud, taps to flip
- Star reward counter for completed rounds

Voice Changer (real-time, in the relay loop):
- Pitch up — chipmunk / high voice
- Pitch down — deep / robot voice
- Robot — vocoder-style metallic tone
- Echo — short room reverb for stage/performance feel
- Megaphone — mid-frequency boost, announcement simulation
- Whisper enhancer — amplify soft speech (accessibility, shy kids)

Animal voices (v2.1, requires SoundTouch):
- **Parrot** — 1.8× pitch + randomised squawk pattern (periodic pitch jump via LFO)
- **Lion / Bear** — 0.45× pitch + low formant boost; growl texture via amplitude modulation
- **Cat** — 0.85× pitch + narrow 800Hz–2kHz mid-boost + gentle tremolo
- **Mouse** — 2.0× pitch + very fast tempo, high formant
- **Alien** — ring modulation at 120Hz + pitch shift (already in v3 Creator mode — share the DSP)
- Technical basis: SoundTouch for clean pitch, biquad formant filters per animal, LFO for organic modulation. All on-device, zero latency impact beyond current voice changer.

**Technical approach:** `AudioTrack.setPlaybackRate()` for v2 launch (already shipped in v1 Kids mode). Upgrade to SoundTouch for clean pitch-shift without tempo change — SoundTouch is open-source (LGPL), integrates via Flutter FFI or Kotlin JNI. All effects must stay within the 50ms latency budget.

**Open-source libraries for v2:**
| Library | Purpose | Integration | Licence |
|---|---|---|---|
| **SoundTouch** | Clean pitch-shift without tempo artefact — replaces `setPlaybackRate()` | Flutter FFI (C++) | LGPL |
| **TFLite / ONNX Runtime** | Runtime for pronunciation scoring and confidence AI models | Flutter plugin | Apache 2 |

AI features in v2:
- **Pronunciation feedback** — on-device speech model listens to child read a word card, flags mispronunciation gently
- **Confidence scoring** — detects volume, pace, and clarity; awards stars per attempt
- **Adaptive word difficulty** — selects next word card based on child's performance history
- **Emotion detection** — detects hesitation or frustration in voice tone, adjusts encouragement prompts

### v3 — Creator Mode
**Audience:** Teenagers
**A third mode — creative toy, not classroom tool.**

- **Clip recording + share** — record a snippet, export via OS share sheet to WhatsApp / Instagram / TikTok
- **Extended voice effects** — Stadium, Deep Fake, Lo-Fi, Alien, Phone Filter, Harmony
- **Live voice visualiser** — animated waveform / spectrum that reacts to voice, front and center
- **Beat backing track** — speak or rap over a looping beat; relay + music mixed to output
- **Duet mode** — two phones, two mics, one Bluetooth speaker for freestyle sessions
- **Voice-to-text overlay** — words appear live on screen as user speaks
- **Custom themes / skins** — user-selectable colour themes, effect preset renaming

AI features in v3:
- **Neural voice effects** — cloud API for quality (on-device TFLite later for speed); celebrity/character voice styles
- **Auto-tune / pitch correction** — real-time pitch correction for singing
- **Lyric / rap generator** — user types a topic, Claude API generates a short rap, teen reads it aloud through voice changer
- **Vibe matching** — detects energy/mood in voice, suggests a matching beat backing track

**Open-source libraries for v3:**
| Library | Purpose | Integration | Licence |
|---|---|---|---|
| **Whisper (whisper.cpp)** | On-device speech-to-text for voice-to-text overlay and transcription | Flutter FFI (C++) | MIT |
| **Claude API** | Lyric / rap generation; not in relay path so cloud latency acceptable | REST API | Pay-per-token |
| **ONNX Runtime** | Neural voice effect inference on-device (future migration from cloud) | Flutter plugin | MIT |

**UX rules for Creator Mode:**
- No account, no sign-up — hard rule
- Effect picker as horizontal scrollable carousel, not a list
- Names matter: effects use attitude ("Alien", "Stadium") not technical labels
- Feels like a creative toy, not an instrument panel

**AI technical rules across all versions:**
| Layer | Runs on | Reason |
|---|---|---|
| Noise suppression, VAD, adaptive gain | On-device (TFLite) | Real-time path — cloud would break 50ms budget |
| Pronunciation scoring, confidence | On-device or hybrid | Near-real-time; latency tolerant |
| Lyric generation, vibe matching | Cloud (Claude / Gemini API) | Not in relay path; quality matters more than speed |
| Neural voice effects | Cloud first, TFLite later | Start with quality, optimize to on-device over time |

### v4 — Polish + Platform
- ~~Foreground service~~ — **shipped in v1 current build** (relay survives screen lock)
- Noise gate — auto-mute below threshold, reduces background bleed
- Preset profiles — save named gain/effect configs ("Outdoor", "Classroom", "Stage")
- Push-to-talk mode — hold to speak, release to mute (structured Q&A)
- Bluetooth device selector — explicitly pick output device
- In-app update nudge for sideloaded / GitHub installs
- Wear OS companion — gain/mute control from smartwatch

## Commercialization Strategy

### Pricing Model — Freemium
| Tier | Includes | Price |
|---|---|---|
| **Free** | Relay + gain (v1 — free forever) | $0 |
| **Practice** | Speech practice mode, word cards, star rewards | $2.99 one-time |
| **Creator** | Voice effects, recording, sharing, themes | $4.99 one-time |
| **Pro** | All modes + presets, noise gate, priority support | $9.99/year |

**Launch strategy:** Ship v1 free, build user base, gate v2 Practice mode behind a $2.99 one-time unlock. School licensing after usage data exists.

### Ad Revenue Strategy

Ads supplement — not replace — the paid tier model. Real ad revenue only materialises at 10k+ DAU; one-time purchases outperform ads below that threshold.

**Ad formats by tier:**

| Format | Placement | Tier | SDK |
|---|---|---|---|
| **Banner** | Bottom of Relay screen | Free only | AdMob |
| **Interstitial** | App open (max once per session) | Free only | AdMob |
| **Rewarded** | "Watch ad → unlock Creator effect for 24h" | Free only | AdMob |

**Rules:**
- All ads removed immediately on any paid purchase — no ads ever shown to paying users
- No ads during an active relay session — audio path must never be interrupted
- No ads in Kids mode — inappropriate for the child audience; keep that screen ad-free
- Rewarded ad is the preferred format — user-initiated, least UX friction, highest CPM
- Interstitial capped at once per session; never show on back-to-back opens

**Implementation (when ready):**
- Package: `google_mobile_ads` (Flutter official AdMob plugin)
- Ad unit IDs stored in `.env` / `--dart-define`, never hardcoded
- Test mode on debug builds; live IDs on release builds only
- COPPA flag set to `true` for Kids mode screens (legal requirement for under-13 content)

**Revenue benchmarks (indicative):**

| Metric | Estimate |
|---|---|
| Banner CPM | $0.50–$2 |
| Interstitial CPM | $3–$8 |
| Rewarded CPM | $8–$20 |
| One-time purchase (Practice) | $2.99 per user, zero ongoing cost |

### Institutional Licensing
| Package | Scope | Price (indicative) |
|---|---|---|
| Teacher license | Single device, all modes | $10/year |
| Classroom pack | 30 devices | $99/year |
| School site license | Unlimited devices, one school | $299/year |
| White-label | Custom branding for edtech / clinics | Setup fee + annual |

Distribution: Google Play for Education or direct APK for managed device fleets.

### Grant Opportunities
App directly serves accessibility and education — eligible for:
- Google.org grants (edtech / accessibility)
- USAID / UNESCO education technology initiatives
- State / national disability inclusion grants
- Speech therapy and special education funding programs

### Competitive Defensibility
- **No PA system needed** — immediate, tangible cost saving for schools
- **Works fully offline** — no Wi-Fi dependency, deployable anywhere
- **No account required** — removes biggest friction for institutional IT approval
- **Open-source core** — builds trust; monetize education-specific features on top
- **Pure relay is a commodity** — differentiation lives in Practice and Creator modes

## Functional Requirements
1. **Live audio relay** — Capture raw PCM 16-bit mono audio from the mic and stream it to whatever output Android currently has active; no forced output targeting.
2. **Gain amplification** — Apply a scalar gain factor (1×–10×) to the PCM byte buffer in real-time via a UI slider.
3. **Runtime permissions** — Request and validate `RECORD_AUDIO`, `BLUETOOTH`, and `BLUETOOTH_CONNECT` at runtime before starting the audio loop.
4. **Start / Stop control** — Toggle the mic-capture and playback loop on demand.

## Non-Functional Requirements
1. **Latency target: < 50ms** — End-to-end round-trip from mic capture to speaker output. This is the primary quality gate. All audio backend decisions must be evaluated against this threshold.
2. **Main thread safety** — Audio processing must never block or lag the UI thread.
3. **Byte efficiency** — Operate directly on `Uint8List` PCM buffers; avoid format conversions or unnecessary allocations in the hot path.
4. **Android API 21+** — Target physical Android devices in USB debug mode.
5. **Null safety** — Strict Dart null-safety compliance throughout.
6. **Const-first UI** — Maximize `const` widget initializations to eliminate unnecessary rebuilds.
7. **Minimal state footprint** — `StatefulWidget` / `ValueNotifier` only; no heavy global state managers.

## Latency Measurement
- A latency overlay widget is included in the UI to benchmark real device round-trip performance.
- **If measured latency exceeds 50ms**: evaluate a native `AudioRecord`/`AudioTrack` platform channel instead of the current Dart-side pipeline.
- **Do not swap the audio backend before measuring on device** — current stack may be sufficient.

## Technical Architecture
- **Audio pipeline:** `record` (`AudioRecorder.startStream`, PCM-16LE) → gain scalar in Dart → `flutter_pcm_sound` output.
- **Output routing:** Defers entirely to Android's active audio output — no `AudioManager` stream type forcing unless latency benchmarks demand it.
- **Gain processing:** Applied per-chunk in Dart via a `ByteData` int16 loop with `clamp(-32768, 32767)`. Acceptable at 16 kHz; re-evaluate if sample rate increases.
- **Sample rate:** 16 kHz mono PCM-16LE. Kept low to minimize buffer size and latency.
- **State management:** `StatefulWidget` with isolated fields; no Provider/Riverpod/Bloc.
- **Security:** Runtime permission validation for `RECORD_AUDIO`, `BLUETOOTH`, `BLUETOOTH_CONNECT`.
- **Package ID:** `com.vel.micify`

## Audio Backend Decision Log
| Decision | Rationale |
|---|---|
| `record` for mic capture | Replaced `mic_stream` (abandoned, incompatible with Flutter v2 embedding); `record` is actively maintained, supports raw PCM streaming via `startStream` |
| `flutter_pcm_sound` for audio output | Replaced `sound_stream` (abandoned, AGP 8.x incompatible); `flutter_pcm_sound` is actively maintained and gives explicit feed/threshold control |
| 16 kHz sample rate | Minimizes per-chunk byte count and internal buffer latency |
| Dart-side gain loop | Avoids platform channel overhead for scalar multiply; revisit if profiling shows Dart GC pressure |
| No forced AudioManager stream type | Let Android route to active output naturally; avoids routing bugs across device variants |

## Core Commands
- Run on connected USB phone: `flutter run`
- Hot reload: Press `r` in terminal
- Hot restart: Press `R` in terminal
- Install dependencies: `flutter pub get`
- Clear build cache: `flutter clean`
- Check environment: `flutter doctor`

## Distribution & Release Strategy

### Versioning

`pubspec.yaml` is the single source of truth:
```yaml
version: 1.0.0+1   # semver + Android versionCode
```
- Display version follows semver: `MAJOR.MINOR.PATCH`
- Build number (`+N`) increments on every Play Store upload — never reuse
- `versionCode` in `android/app/build.gradle` must match the build number

| Version | Milestone | Status |
|---|---|---|
| `1.0.0+1` | v1 Relay — initial release | **current** |
| `1.1.0+2` | v1.1 AI-enhanced relay (noise suppression, VAD, adaptive gain) | planned |
| `2.0.0+3` | v2 Practice + Voice Changer (Kids mode shipped early in v1) | planned |
| `3.0.0+4` | v3 Creator Mode (clip recording, beat backing, visualiser) | planned |
| `4.0.0+5` | v4 Polish + Platform (noise gate, presets, Wear OS, in-app updates) | planned |

### Distribution Channels

| Channel | When | Command |
|---|---|---|
| **GitHub Releases** | Pre-v1 / early testers / open-source | `flutter build apk --release --split-per-abi` |
| **Google Play** | v1.0 public launch | `flutter build appbundle --release` |

**Play Store setup (one-time):**
1. Generate keystore: `keytool -genkey -v -keystore micify.jks -alias micify -keyalg RSA -keysize 2048 -validity 10000`
2. Wire into `android/app/build.gradle` via `key.properties` (gitignored — never commit the keystore)
3. $25 one-time Google Play developer fee

### Release Process

1. Bump version in `pubspec.yaml`
2. Update `CHANGELOG.md` under `claudedocs/`
3. Build signed artifacts:
   - Play Store: `flutter build appbundle --release`
   - GitHub / sideload: `flutter build apk --release --split-per-abi`
4. Tag git commit: `git tag v1.0.0`
5. GitHub: attach per-ABI APKs to the release; Play Store: upload AAB

### App Size Optimisation

| Technique | Saving | When |
|---|---|---|
| `--release` build | 30–40% — removes debug symbols, enables Dart tree-shaking | Every public build |
| `--split-per-abi` | 60–70% — users download only their ABI (arm64 / arm / x86_64) | GitHub / sideload releases |
| App Bundle (AAB) on Play Store | Play delivers per-device optimised APK automatically | Play Store uploads |
| ProGuard / R8 | 10–20% on Kotlin side — enabled by default in release builds | No action needed |
| Avoid unused assets / fonts | Marginal — audit `pubspec.yaml` assets before each release | Pre-release check |

**Target:** Play Store install size < 15 MB. Debug APK will be larger (25–40 MB) — normal, never ship debug to users.

### Update Delivery

- **Play Store users** — silent OTA updates; no action needed from user
- **GitHub / sideload users** — must manually download new APK; in-app update nudge planned for v4
- **No forced updates** — Micify works fully offline; never break existing installs

### Open-Source Rules

- Core relay (v1) stays free and open-source forever
- Paid features (Practice, Creator) gated via Play Store one-time purchase or subscription
- Keystore, signing keys, and `.env` files are never committed to the repo

## Code Style
- Null-safe Dart; `final` by default, mutable only when required.
- `const` constructors wherever possible.
- 2-space indentation; trailing commas on multi-line calls.
- No comments unless the WHY is non-obvious.
