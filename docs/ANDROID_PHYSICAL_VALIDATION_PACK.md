# Android Physical Validation Pack (G5 phone path)

State: **PHYSICAL_VALIDATION_READY** — everything below is built and tested
without hardware (Dart/Console tests, Kotlin JVM tests, CI APK build). No
number in this pack is MEASURED until a person runs it on a physical phone.

Loop under test: **mic → STT → translation → TTS → (speaker) → mic**.

| Item | State until a physical run |
|---|---|
| ECHO_RISK (self-echo on the phone speaker path) | BLOCKED_HARDWARE — detection ready, not observed |
| AEC (`VOICE_COMMUNICATION` + AcousticEchoCanceler) | BLOCKED_HARDWARE — selectable, availability unknown per device |
| `speechEndToFinal` and every other latency on device | BLOCKED_HARDWARE — only EMULATED/SIMULATED numbers exist |
| `speechQueuedToAudible`, `speechEndToAudible` | BLOCKED_HARDWARE — measurable path built; UNKNOWN until a phone reports it |
| Kotlin / JVM | VERIFIED in CI (`android-apk` job compiles Kotlin and runs `ValidationSupportTest`, `TtsPresentationTest`) |

## What the pack adds

| Piece | Where | Tested by |
|---|---|---|
| STT epoch fix (STT never started on device: 64-bit epoch read as Int) | `MainActivity.prepareStt`, `ValidationSupport.epochOf` | `ValidationSupportTest` (JVM, CI) |
| `onEndOfSpeech` / `onBeginningOfSpeech` capture (platform monotonic clock) | `MainActivity` → `speechStarted`/`speechEnded` STT events | provider tests (`android_live_translation_providers_test`) |
| `speechEndToFinal` latency | provider attaches `speechEndedAtMicros`; runtime emits the sample | `speech_boundary_test`, Console `latency.test.ts` |
| Capture source A/B: `VOICE_RECOGNITION` vs `VOICE_COMMUNICATION` (+ AEC) | intent extra `horizon.audioSource`, debuggable builds only | `ValidationSupportTest`, microphone adapter test |
| Self-echo suspicion | runtime `selfEchoSuspected` diagnostic (`duringTts` / `afterTts`, `.textOverlap`) | `speech_boundary_test`, validation golden |
| Redacted logging | `ValidationRecorder` (redacted v1 NDJSON + coded sidecar) | `validation_recorder_test` |
| Offline analysis | Engineering Console → "load an offline .ndjson file" | Console tests on runtime-produced goldens |
| Observable speech output (`speechQueuedToAudible`, `speechEndToAudible`) | `MeasuredTtsOutput` + `TtsPresentation` → provider `presentations` → runtime latency | `TtsPresentationTest` (JVM, CI), provider tests, `turn_latency_test`, Console `latency.test.ts` |

### What "audible" means here

The TTS engine synthesizes into `/dev/null` (API 30+, nothing stored) and
streams the audio to the app (`onAudioAvailable`), which plays it through its
own `AudioTrack`. The boundaries, all on CLOCK_MONOTONIC (the clock of
`System.nanoTime`, `AudioRecord` timestamps and `onEndOfSpeech`):

| Boundary | Source |
|---|---|
| queued | `System.nanoTime` when the utterance is handed to the engine |
| first frame presented | `AudioTrack.getTimestamp`, interpolated back to frame 0 |
| audible frame presented | same, for the first frame above about -40 dBFS (leading silence skipped) |
| playback completed | the timestamp covers the last written frame (closes the self-echo window) |

A frame's time is only taken from a timestamp that already covers it; a frame
not yet presented is never predicted. **Presented is what AudioTrack reports
for the output path: it is not acoustic arrival and not what a person heard.**
An acoustic reference recording is still needed to bound the difference.

If the engine does not stream audio to the app (probed at every prepare), it
plays the utterance itself, `ttsMeasuredOutput` is `false` in the sidecar with
`ttsOutputReason`, and both audible stages stay UNKNOWN. Stopped, stalled or
malformed presentations are also UNKNOWN, never estimated.

Privacy: the recorder writes only the redacted `horizon.runtime-event.v1`
stream (no audio, transcript or translation text) and a sidecar that accepts
only booleans, integers and short coded tokens.

## 0. Requirements

- Android 13+ (API 33; the on-device PFD recognizer needs it) with on-device
  speech recognition available for `en-US` and `es-ES`.
- ML Kit en↔es models (downloaded on first run with the download consent) and
  a TTS voice for the target locale.
- `adb` on a computer, USB debugging enabled.
- A quiet room, the phone on a table, speaker volume at a fixed level
  (record it), the speaker about 40 cm from the phone.

## 1. Get the APK

Either download the CI artifact `horizon-validation-apk-debug` from the
`verify` run of the commit under test:

```bash
gh run download <run-id> --repo JuanMaPerals/persalone-horizon -n horizon-validation-apk-debug
```

or build it locally:

```bash
cd apps/mobile && flutter build apk --debug --dart-define=HORIZON_VALIDATION_LOG=true
```

Install:

```bash
adb install -r app-debug.apk
```

## 2. Run variant A (`voiceRecognition`, default)

```bash
adb shell am start -S -n com.example.persalone_mobile/.MainActivity --es horizon.audioSource voiceRecognition
```

Find the log file (only the path is logged):

```bash
adb logcat -d | grep HORIZON_VALIDATION_LOG
```

If it prints `HORIZON_VALIDATION_LOG unavailable`, stop: the run is not being
recorded.

In the app: grant the microphone, give the session consent, start G5.

### Script (identical for both variants)

1. **Loop and echo check (10 phrases).** Read one phrase (list at the end),
   wait until the translation has finished playing, then stay silent for 5 s.
   Nobody speaks during the silence: any final turn that appears then is echo.
2. **Barge-in (3 times).** Start the next phrase while the translation is still
   playing.
3. **Stop** from the app, then **Panic** once in a new session.

For every phrase, note by hand (the log has no text) whether the transcript
and translation shown on screen were correct.

## 3. Run variant B (`voiceCommunication`)

```bash
adb shell am start -S -n com.example.persalone_mobile/.MainActivity --es horizon.audioSource voiceCommunication
```

Repeat the same script with the same volume and positions.

## 4. Pull the logs

For each variant (`<path>` from step 2):

```bash
adb exec-out run-as com.example.persalone_mobile cat <path> > variant-A.ndjson
```

```bash
adb exec-out run-as com.example.persalone_mobile cat <path-without-.ndjson>.meta.json > variant-A.meta.json
```

The sidecar must show the source actually used (`audioSource`) and whether
the echo canceller was available and enabled (`aecAvailable`, `aecEnabled`).
If `audioSource` does not match the variant, discard the run.

It also shows the speech output path (`ttsMeasuredOutput`, `ttsOutputReason`).
With `false`, the audible stages must read UNKNOWN; any audible sample in such
a run means the log is wrong and the run is discarded.

## 4b. Optional: watch the run live in Studio

Validation builds also serve the same redacted stream, read-only, on the
phone's **loopback** at port 47800 (logcat prints `HORIZON_LIVE_STREAM`). The
computer reaches it only through adb, so nothing listens on the LAN:

```bash
adb forward tcp:47800 tcp:47800
```

```bash
cd apps/engineering-console && corepack pnpm@10 dev --host 127.0.0.1
```

Open Studio at `http://127.0.0.1:5173`, Runtime panel, keep the default URL
`http://127.0.0.1:47800/v1/runtime-events`, connect. Only the origins
`http://127.0.0.1:5173` and `http://localhost:5173` may read it (build-time
`HORIZON_STUDIO_ORIGINS` changes the list; `HORIZON_LIVE_STREAM_PORT` the
port). Remove the forward afterwards:

```bash
adb forward --remove tcp:47800
```

Studio can only **watch**. Stop and Panic stay on the phone: the remote
control gateway has no authenticated transport yet, and adding one is a
security-boundary decision (BLOCKED_AUTHORIZATION).

## 4c. Halo captions (only with a physical Halo)

The default APK composes **no** caption output, so no run carries a HALO_REAL
label. A build for a Halo session enables the Brilliant BLE caption path:

```bash
cd apps/mobile && flutter build apk --debug --dart-define=HORIZON_VALIDATION_LOG=true --dart-define=HORIZON_HALO_CAPTIONS=true
```

The app then shows "Conectar Halo". Delivered captions are at most PREPARED
(device acknowledgement); what the wearer saw is recorded by hand. Known
blocker: the app does not yet declare or request `BLUETOOTH_SCAN` /
`BLUETOOTH_CONNECT`, so discovery is expected to fail on Android 12+ until
that permission change is authorized. Captions are then BLOCKED, never
faked, and translation and speech continue.

## 5. Read the results

Load each `.ndjson` in the Engineering Console (Runtime panel → offline file).
It shows, per variant:

- `speechEndToFinal`, `finalToTranslation`, `finalToSpeechQueued`,
  `speechQueuedToAudible`, `speechEndToAudible`: latest / p50 (5+ samples) /
  p95 (20+ samples);
- "Self-echo suspected" (and how many with text overlap);
- DEGRADED if any line was rejected or a sequence is missing.

Counts that the Console does not show, from the file:

```bash
grep -c '"code":"transcriptFinal"' variant-A.ndjson
```

```bash
grep -c '"code":"selfEchoSuspected"' variant-A.ndjson
```

```bash
grep -c '"code":"speechEnded"' variant-A.ndjson
```

## 6. Pass criteria

| Check | Pass |
|---|---|
| STT starts (epoch fix) | session reaches `listening`, no `providerUnavailable` at start |
| End-of-speech measured | `speechEnded` count ≥ phrases spoken, `speechEndToFinal` samples ≥ 20 over both runs |
| No self-echo (loop and echo check) | during the 5 s silences: no extra `transcriptFinal`, `selfEchoSuspected` = 0 |
| Barge-in | the spoken translation stops when the person speaks; the new turn is translated |
| Stop / Panic | TTS stops, no further turn is spoken |
| Redaction | `grep -ciE 'station\|pharmacy\|flight\|tomorrow\|estacion\|farmacia\|vuelo\|manana' variant-*.ndjson variant-*.meta.json` prints 0 for every file |

## 7. ECHO_RISK decision (A/B)

- Echo in A and not in B, with B's manual accuracy ≥ A's and B's
  `speechEndToFinal` p50 not worse by > 20 %: propose `voiceCommunication` as
  the default (separate change).
- Echo in both: echo cancellation is not enough on that device; a mitigation
  (e.g. muting STT while TTS plays) is required before release.
- No echo in either: keep `voiceRecognition`, record the device and volume.

Record: device model, Android version, volume, distance, room, date, APK
commit, both sidecars, and the manual accuracy table. Evidence without these
fields is not accepted.

## Phrase list (English source)

1. Good morning, how are you today?
2. Where is the train station?
3. I would like a table for two people.
4. Can you speak a little more slowly, please?
5. How much does this cost?
6. My flight leaves at seven in the evening.
7. Is there a pharmacy near here?
8. Thank you very much for your help.
9. I do not understand, can you repeat that?
10. See you tomorrow at the office.
