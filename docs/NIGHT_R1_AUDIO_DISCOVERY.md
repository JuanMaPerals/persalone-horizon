# Night R1 — audio processing discovery (AEC / NS / VAD / diarization / overlap)

Read-only discovery on `feat/night-r1`. Nothing was implemented: every
candidate change lives in Kotlin (`MainActivity.kt`), and neither this host
(no Android SDK) nor CI (`verify.yml` builds no APK) can compile or test it.
Implementing it would be `PREPARED`, not product progress.

## Current audio path (as code, not as assumed)

- Phone capture: `AudioRecord` with `MediaRecorder.AudioSource.VOICE_RECOGNITION`,
  mono PCM16 (`MainActivity.kt`, capture setup). No `android.media.audiofx`
  effect is attached anywhere in the repo.
- STT: `SpeechRecognizer.createOnDeviceSpeechRecognizer`, fed through a PCM
  pipe (`EXTRA_AUDIO_SOURCE`), `EXTRA_PREFER_OFFLINE`, partial results on.
- Recognition listener: `onBeginningOfSpeech`, `onEndOfSpeech`,
  `onRmsChanged` are all `= Unit` (dropped). Final/partial results carry
  `observedAtMicros = System.nanoTime() / 1000` (monotonic).
- TTS: platform TTS on the phone; the runtime stops synthesis before each new
  final turn (barge-in boundary). The microphone keeps capturing while TTS
  plays.
- Halo path: Halo microphone and Halo speaker adapters over the official
  transport (`halo_real_audio_adapters.dart`); no processing controls exposed.

## Classification

| Capability | Phone path | Halo path | Evidence |
|---|---|---|---|
| AEC | AVAILABLE_NOT_ACTIVE | UNKNOWN | No `AcousticEchoCanceler` attached; source is `VOICE_RECOGNITION`, not `VOICE_COMMUNICATION` (the Android docs describe the latter as the source that uses echo cancellation when available). Device availability (`AcousticEchoCanceler.isAvailable()`) is UNKNOWN until measured. |
| NOISE_SUPPRESSION | AVAILABLE_NOT_ACTIVE | UNKNOWN | No `NoiseSuppressor` attached. Whatever the on-device recognizer does internally is not observable: UNKNOWN. |
| VAD / endpointing | ACTIVE inside the recognizer; its signals AVAILABLE_NOT_ACTIVE | UNKNOWN | The recognizer endpoints (it emits final results), but `onBeginningOfSpeech`/`onEndOfSpeech` are dropped, so end-of-speech is unobservable and `speechEndToFinal` latency stays UNKNOWN. |
| DIARIZATION | UNAVAILABLE | UNAVAILABLE | `SpeechRecognizer` exposes no speaker labels; capture is mono. |
| OVERLAP_DETECTION | UNAVAILABLE | UNAVAILABLE | Mono capture, no API. The runtime orders overlapping *turns* (tested), which is not overlapping *speakers*. |

## Product risk found

`ECHO_RISK`: on the phone path, TTS plays from the speaker while the
microphone stays open on a source without echo cancellation. The translated
speech can be captured and recognised as a new turn (a feedback loop). The
barge-in stop only limits how long the echo lasts; it does not prevent it.
Not observed on hardware yet (`BLOCKED_HARDWARE`); it must be one of the
first physical checks.

## Smallest next steps (need an Android toolchain or a device)

1. **Measure endpointing** (official, small, no new architecture): record
   `System.nanoTime()` in `onEndOfSpeech` and attach it to the next final
   result event; the Dart provider forwards it and the runtime emits
   `speechEndToFinal` as an interval whose two ends share Android's monotonic
   clock. Turns one UNKNOWN latency row into MEASURED on device.
2. **AEC A/B on a physical phone**: `VOICE_RECOGNITION` vs
   `VOICE_COMMUNICATION` (+ `AcousticEchoCanceler` when available) with TTS
   playing; measure self-recognised turns and recognition quality. Keep the
   variant only if it removes echo without hurting recognition or latency.
3. Add an APK build to CI (or a local SDK) so Kotlin changes stop being
   untestable.
