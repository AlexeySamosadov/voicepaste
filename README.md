# VoicePaste

A macOS menu bar dictation app. Press `Cmd+Shift+R`, talk, and the transcribed text is copied to your clipboard, ready to paste anywhere your cursor is.

VoicePaste is built around four pipeline stages, each added in a numbered phase:

- **Phase 1** - Silero VAD silence detection (auto-stop after a quiet pause).
- **Phase 2** - Per-segment speaker identification (only your enrolled voice gets transcribed; other voices are filtered out).
- **Phase 3** - 80 - 3400 Hz bandpass filter to suppress AC hum and high-frequency noise before the model sees the audio.
- **Phase 4** - Live speaker-gated silence timer. The 5-second auto-stop counts only YOUR voice. Recording stops 5 s after your last word, even if Alice / a colleague / the TV keeps talking.

It runs as an `LSUIElement` (no Dock icon, just a menu bar mic).

> Кратко по-русски: меню-бар приложение для голосового ввода. Нажал `Cmd+Shift+R`, наговорил, отпустил - текст в буфере. Распознаёт только твой голос (по слепку), фоновых не транскрибирует.

## Screenshots

(coming soon)

## Requirements

- macOS 14 (Sonoma) or newer (`LSMinimumSystemVersion` is 13, but the FluidAudio CoreML graphs target macOS 14+)
- Xcode 15 / Command Line Tools (Swift 5.9+)
- An API key from one of: **OpenRouter**, **OpenAI**, or **Groq** (all configurable from the in-app **Settings...** window). The key is stored in macOS Keychain.
- About 250 MB of disk for the FluidAudio model download (cached under `~/Library/Caches`)
- Microphone permission (granted on first launch)

## Quick start

```bash
git clone https://github.com/<your-username>/voicepaste.git
cd voicepaste

# Build and install the app bundle
make install

# Launch
open VoicePaste.app
```

On first launch VoicePaste pops up a "Settings" prompt. Open it, pick a transcription provider (OpenRouter / OpenAI / Groq), paste your API key, click **Test Connection**, then **Save**. The key is stored in macOS Keychain - never in `config.json` or any file you might accidentally commit.

After that, macOS asks for microphone permission. Grant it, then click the menu bar mic and click **+ Add** in the Voice Profiles section to enroll your voice (3 short clips, 5 s each).

After that, `Cmd+Shift+R` from anywhere starts recording. Talk. Stop talking. Five seconds later it auto-stops, transcribes, and the text lands on your clipboard. `Cmd+V` to paste.

## Day-to-day workflow

### 1. Launch

`open VoicePaste.app` (or use the LaunchAgent below for autostart). The app does NOT show a Dock icon - look at the menu bar (top-right of the screen). The icon's state tells you what's happening:

| Icon | Meaning |
|------|---------|
| Gray mic | Idle, ready to record |
| Red `● REC 0:14` | Recording, with elapsed time |
| Pulsing ellipsis | Processing (sending audio to Whisper) |
| Red exclamation banner in popover | An error - check the message |

### 2. Enroll your voice (one-time)

Click the menu bar mic to open the popover. Find the **Voice Profiles** section. Click **+ Add**.

- Type a name (e.g. `me`, `me-hoarse`, `me-morning`).
- Record three 5-second clips. Speak naturally - say a different sentence in each clip. The mean of the three embeddings becomes your profile.
- Click **Save profile**. The file is stored at `~/.config/voicepaste/voiceprints.json`.

### 3. Start dictating

Two ways:

- **Hotkey**: `Cmd+Shift+R` from any app. Talk. The hotkey is registered globally, so you don't need VoicePaste in focus.
- **Click Start Recording** in the popover.

The `Level`, `VAD`, and `Silence` bars in the popover show real-time:

- **Level** - microphone RMS amplitude.
- **VAD** - Silero voice-activity probability (0.0 - 1.0; speech is typically > 0.5).
- **Silence** - seconds since YOUR last matched word. When this hits the configured `silenceDuration` (default 5 s), recording auto-stops.

### 4. Stop / auto-stop

Either press `Cmd+Shift+R` again, or stay quiet for 5 seconds. The transcription appears in the **Recent** section and is copied to the clipboard automatically. `Cmd+V` to paste.

### 5. Review per-segment matches

Each Recent entry shows the underlying speech segments. A green check means "matched your profile and was transcribed". A red X means "rejected - somebody else was talking, this segment was dropped".

If a real word of yours got rejected (because you spoke quietly, or the mic position changed), click **Should have passed?** next to the rejected segment. The rejected embedding is blended into your profile (running mean, weight 0.25), so similar future audio will pass. This is the **online-learning** path - use it sparingly; merging too many borderline segments will eventually drift the profile.

### 6. Manage profiles

- **Add another**: enroll a second profile under a different name. Useful if you sometimes have a hoarse / morning / quiet voice that the original profile doesn't recognize. Both profiles run in parallel - if EITHER matches, the segment is kept.
- **Delete**: trash icon next to the profile name in the popover.
- **Re-enroll**: delete and add again.

### 7. Quit

The popover footer has a **Quit** button. Or use Activity Monitor.

## Hotkey reference

| Hotkey | Action |
|--------|--------|
| `Cmd+Shift+R` | Toggle recording (start / stop / interrupt processing) |

## Settings window

Open the menu bar popover and click **Settings...** (or VoicePaste pops it up automatically when no API key is configured). The window has two sections:

### Transcription Provider

| Field | What it does |
|-------|--------------|
| **Provider** | OpenRouter, OpenAI, or Groq. Switching providers automatically reloads the API key associated with that provider. |
| **Model** | Dropdown of suggested models for the selected provider, plus a "Custom..." option for any model name. OpenAI: `whisper-1`. Groq: `whisper-large-v3` / `whisper-large-v3-turbo` / `distil-whisper-large-v3-en`. OpenRouter: `openai/whisper-1`. |
| **API Key** | Pasted into a SecureField. Saved to macOS Keychain under service `com.alexey.voicepaste.providerKeys`, account = provider id. **Never written to config.json.** |
| **Language** | Optional ISO-639-1 hint (`ru`, `en`, ...). Empty = auto-detect. |
| **Test Connection** | OpenAI / Groq: sends a 1-second silent WAV; a green check means key+model are both valid. OpenRouter: GETs `/api/v1/models` instead. Errors are shown inline in red. |

### Audio

| Field | What it does |
|-------|--------------|
| **Voice activity detection** | Use Silero VAD for speech segmentation. Disable only if VAD model fails to load. |
| **VAD threshold** | Slider 0–1. Lower = more permissive (catches whispers and breath); higher = stricter. |
| **80–3400 Hz bandpass filter** | Phase 3 noise removal applied before VAD and the embedder see audio. |
| **Only transcribe my voice** | Phase 4 speaker verification: silence timer counts only your matched speech, and only segments matching an enrolled profile are sent to Whisper. |
| **Silence auto-stop after** | Seconds (1–30) of (your) silence before recording auto-stops. |

Settings are saved to `~/.config/voicepaste/config.json` and applied live - no relaunch needed.

## Full config reference (advanced)

`~/.config/voicepaste/config.json` is a flat JSON file. The Settings window writes it for you, but you can also hand-edit if you prefer. **Do NOT put API keys here** - they live in the Keychain.

```json
{
  "providerId": "openrouter",
  "providerModel": "openai/whisper-1",
  "language": "ru",
  "silenceDuration": 5.0,
  "silenceThreshold": 0.01,
  "vadEnabled": true,
  "vadThreshold": 0.5,
  "audioFilterEnabled": true,
  "liveSpeakerVerification": true
}
```

| Field | Type | Default | What it does |
|-------|------|---------|--------------|
| `providerId` | string | `"openrouter"` | One of `"openrouter"`, `"openai"`, `"groq"`. Picks which built-in `TranscriptionProvider` to use. |
| `providerModel` | string | `"openai/whisper-1"` | Model name passed in the multipart `model` field. |
| `language` | string \| null | `null` | ISO-639-1 hint for Whisper (`"ru"`, `"en"`, `"de"`, ...). `null` = auto-detect. Setting it improves accuracy for non-English speech. |
| `silenceDuration` | number | `5.0` | Seconds of (your-voice) silence before auto-stop. Phase 4 counts only YOUR speech, not other voices. |
| `silenceThreshold` | number | `0.01` | Legacy RMS gate. Only used when `vadEnabled = false`. Lower = more sensitive. |
| `vadEnabled` | bool | `true` | Use Silero VAD for speech detection. Set to `false` only if VAD model fails to load. |
| `vadThreshold` | number | `0.5` | Probability cutoff for "this is speech". Lower (e.g. 0.3) = more permissive (catches whispers but also breath noise). Higher (e.g. 0.7) = stricter. |
| `audioFilterEnabled` | bool | `true` | Enable the Phase 3 80 - 3400 Hz bandpass filter. Removes 50/60 Hz hum and high-frequency hiss before VAD and embedder see the audio. |
| `liveSpeakerVerification` | bool | `true` | Phase 4: silence timer counts only your matched voice. Set to `false` to fall back to any-speech VAD silence (Phase 1 behavior). |

### Legacy fields (auto-migrated, do not use)

Older versions stored `apiKey`, `baseURL`, `model`, and `openrouterApiKey` directly in `config.json`. **These are deprecated.** On first launch the new build:

1. Maps `baseURL` → `providerId` (api.openai.com → `openai`, openrouter.ai → `openrouter`, groq.com → `groq`)
2. Copies `apiKey` (and `openrouterApiKey`) into the macOS Keychain
3. Strips all four legacy keys from `config.json`

The migration runs once and is idempotent. If you find these fields back in your file, the app probably crashed mid-write - re-run it and they will be cleaned up.

### When to change defaults

- **Quiet speaker / soft voice**: lower `vadThreshold` to `0.35` and re-enroll your voice while speaking the same way.
- **Noisy environment (cafe, shared office)**: keep `vadThreshold` at `0.5`, ensure `audioFilterEnabled = true`, and lean on `liveSpeakerVerification = true` so background voices are filtered.
- **Very long pauses while thinking**: increase `silenceDuration` to `8.0` or more.
- **No enrolled profile yet**: set `liveSpeakerVerification = false` so the silence timer falls back to any-voice VAD until you enroll.

## Voice profile enrollment guide

### Why 3 clips?

A single 5-second sample is too short and too narrow to capture how your voice actually varies (intonation, microphone distance, room acoustics, time of day). The mean of three independent recordings is a more stable embedding centroid - similar in spirit to test-time-augmentation. If you only record one clip, expect more false-rejections on natural speech variation.

### How to record clearly

- Sit at your normal mic distance. If you'll dictate at the laptop, enroll at the laptop.
- Speak **different sentences** in each of the three clips. Reading the same sentence three times overfits to that one prosody.
- Speak naturally - not louder than normal, not over-articulated. Whisper is your end consumer; the embedder should match the same speech style.
- No need to fill the entire 5 seconds with words. Pauses are fine.

### When to add a second profile

Add another profile (under a different name) if your voice varies a lot between sessions:

- `me` - normal awake voice
- `me-hoarse` - first thing in the morning, or when you're sick
- `me-quiet` - when whispering at night so you don't wake people up
- `me-headset` - if you use a different mic sometimes

When multiple profiles are enrolled, a segment passes if ANY profile matches. So adding a second profile only ever increases your true-positive rate.

### Per-profile threshold

Each profile has its own `threshold` (default `0.55`, cosine similarity 0..1). The popover shows it as `thr 0.55` next to the profile name. You can edit `~/.config/voicepaste/voiceprints.json` directly to tune it:

- Higher (e.g. `0.65`) = stricter, fewer false matches from background voices, but you may need to re-enroll more often.
- Lower (e.g. `0.45`) = more permissive, may catch background voices that sound like you.

### Where the file lives

```
~/.config/voicepaste/voiceprints.json
```

Format: array of `{id, name, embedding[256], threshold, enrolledAt}`. The embedding is L2-normalized 256-d float from FluidAudio's WeSpeaker CoreML graph. Compare with cosine similarity (= dot product, since vectors are unit norm).

### Delete and re-enroll

- Click the trash icon next to the profile in the popover.
- Or delete `~/.config/voicepaste/voiceprints.json` to wipe all profiles.
- Then **+ Add** again.

## Privacy and data flow

What leaves the machine:

- **Audio bytes** are sent to your configured `baseURL` (OpenAI / OpenRouter / etc.) only after a recording stops AND only the segments that matched at least one of your enrolled voice profiles. Background voices, unmatched segments, and silence are never uploaded.

What stays local:

- **Voice profiles** at `~/.config/voicepaste/voiceprints.json` - never leaves the device.
- **Transcription history** (last 20 entries) lives in memory while the app runs; it's not persisted to disk.
- **Raw recordings** under `~/.config/voicepaste/recordings/` - kept on disk so you can retry failed transcriptions; the most recent 50 are kept, older ones auto-pruned. Successful transcriptions delete their wav file on success.
- **Logs** at `~/.config/voicepaste/phase4.log` - speaker-verification diagnostic trace. Local only.
- **API key** in macOS Keychain (service `com.alexey.voicepaste.providerKeys`, one entry per provider) - local only, never in `config.json`. Inspect with `security find-generic-password -s com.alexey.voicepaste.providerKeys -a openai -g`.

VoicePaste does no telemetry, no analytics, no auto-update.

## Troubleshooting

### Mic indicator stuck red ("REC ...") and never auto-stops

Open the popover. If the **Silence** bar is at `0.0s / 5s` while you're quiet, then either (a) Phase-4 live verification is off, or (b) a non-user voice is being mis-matched.

- Verify `liveSpeakerVerification: true` in config and that you have at least one profile enrolled.
- Tail the diagnostic log:
  ```bash
  tail -f ~/.config/voicepaste/phase4.log
  ```
  Look for `[Phase4] embed#N matched=true sim=0.6X best=<name>` lines while you're quiet. If similarity > your profile's threshold for non-you audio, raise the threshold or re-enroll.
- Press `Cmd+Shift+R` to manually stop, no harm done.

### "No profiles enrolled. All audio will be transcribed" warning

You haven't enrolled a voice yet. Click **+ Add** in Voice Profiles. Until then, every voice in the room gets transcribed.

### "Speaker model load failed" error

FluidAudio downloads the WeSpeaker CoreML model from HuggingFace on first launch. If the download fails (no internet, HF rate-limit), you'll see this. Solutions:

```bash
# Check internet, then restart the app
make redeploy
```

If the model is repeatedly failing to load, clear the FluidAudio cache and try again:

```bash
rm -rf ~/Library/Caches/FluidAudio
make redeploy
```

### Metal/CoreML cache crash (`BUG IN CLIENT OF LIBMALLOC`)

Symptom: app silently dies. Crash report under `~/Library/Logs/DiagnosticReports/VoicePaste-*.ips` mentions `MTLCompilerFSCache::getElement` or `_xzm_xzone_malloc_freelist_outlined`.

Recovery:

```bash
pkill -x VoicePaste
rm -rf ~/Library/Caches/com.alexey.voicepaste/com.apple.metal
rm -rf ~/Library/Caches/com.alexey.voicepaste/com.apple.e5rt.e5bundlecache
rm -rf ~/Library/Caches/com.alexey.voicepaste/fsCachedData
make redeploy
```

The OS will rebuild the Metal/ANE shader caches the next time CoreML runs - first recording after the wipe may be ~1 s slower while shaders compile.

### How to inspect the diagnostic log

```bash
tail -f ~/.config/voicepaste/phase4.log
```

Every `~500 ms` while recording you'll see lines like:

```
03:40:55.500 [Phase4] tick prob=0.97 sinceUserSpeech=0.20 recentUser=true hasAudio=true silAge=-1.00 ...
03:40:56.000 [Phase4] embed#7 bufSamples=66150 bufRate=44100 matched=true sim=0.683 best=yes streak=2/2 -> lastUserSpeechAt=0.00s ago
03:40:59.904 [Phase4] auto-stop: silence 5.0s, secondsSinceUserSpeech=6.61
```

`matched`, `sim`, `streak`, and `silAge` are the most useful columns when diagnosing why a recording did or didn't auto-stop.

### Redeploy after editing code

```bash
make redeploy
```

This runs `make install`, then restarts the app through the LaunchAgent if you installed one (so launchd keeps supervising it), or kills and relaunches it otherwise. Do NOT use `open VoicePaste.app` to "restart" - it stacks up multiple instances.

Because the bundle is signed ad-hoc, every rebuild changes its code signature and macOS asks for **microphone access again** on the first recording after a redeploy. Click Allow; the recording made while that dialog is up comes out empty (0 frames) and shows up as an "Audio file is too short" error - just record again.

### Multiple instances running

```bash
pgrep -lf VoicePaste | wc -l   # should be exactly 1
```

If it returns > 1:

```bash
pkill -x VoicePaste
sleep 1
make redeploy
pgrep -lf VoicePaste | wc -l   # confirm 1
```

### Autostart on login and auto-restart after a crash

```bash
make install-agent     # build, bundle, install ~/Library/LaunchAgents/com.alexey.voicepaste.plist, start now
make uninstall-agent   # stop it and remove the agent
```

The agent (template in `launchd/com.alexey.voicepaste.plist.in`) sets `RunAtLoad` and `KeepAlive = {SuccessfulExit: false}`: VoicePaste starts at login and launchd relaunches it within ~10 s after a crash or `kill -9`, but a normal Quit (or `pkill -x VoicePaste`) stays quit until the next login. `make redeploy` restarts it explicitly.

```bash
launchctl print gui/$(id -u)/com.alexey.voicepaste | head -20   # state, pid, last exit reason
```

### Crash log

Every launch, clean exit, uncaught exception and fatal signal is appended to `~/.config/voicepaste/crash.log`:

```
==== 2026-09-10 13:38:05 +0300 launch pid 43834 version 1.0 binary-built 2026-09-10 13:37:12 +0300
==== 2026-09-10 03:31:46 +0300 UNCAUGHT EXCEPTION pid 83709 uptime 498993s
com.apple.coreaudio.avfaudio: Failed to create tap due to format mismatch, <AVAudioFormat: 1 ch, 44100 Hz, Float32>
0   CoreFoundation  ... __exceptionPreprocess + 176
5   VoicePaste      ... AudioRecorder.startRecording() + 3708
==== FATAL SIGNAL SIGABRT pid 83709 epoch 1789000306
(backtrace omitted: the uncaught exception above is the cause)
==== 2026-09-10 13:38:05 +0300 previous session pid 83709 (launched 2026-09-03 18:29:39 +0300) did not exit cleanly; macOS crash report: ~/Library/Logs/DiagnosticReports/VoicePaste-2026-09-10-033152.ips
```

The exception **reason** is the line macOS's own `.ips` reports do not contain, so check this file first. If the app died without any handler running (SIGKILL, logout, power loss) the next launch still writes a "did not exit cleanly" line and links the newest `.ips` report if there is one.

```bash
tail -50 ~/.config/voicepaste/crash.log
```

## Architecture

```
                   AVAudioEngine input tap (system rate, mono Float32)
                                 |
                                 v
                       AudioFilter (80 - 3400 Hz bandpass)         <- Phase 3
                                 |
                                 v
              VADService (FluidAudio Silero, 16 kHz frames)        <- Phase 1
                                 |
                                 v
            SpeechSegmenter (probability hysteresis,                <- Phase 2
              hangover, min/max segment length)
                                 |
                                 v
              SpeakerEmbedder (FluidAudio WeSpeaker, 256-d         <- Phase 2
                L2-normalized) -> VoiceprintStore.anyMatch
                                 |
                                 v
        AudioRecorder.checkActivity (Phase-4 silence gate           <- Phase 4
        based on lastUserSpeechAt, with 2-of-N consecutive
        match debouncing to suppress false positives)
                                 |
                                 v
               TranscriptionService (Whisper HTTP /v1/audio/transcriptions)
                                 |
                                 v
                       Pasteboard + popover history
```

`SpeakerEmbedder` is an `actor` - all CoreML inference is serialized across live per-500 ms gating, post-stop segment matching, and enrollment. Concurrent calls to FluidAudio's `DiarizerManager` corrupted the shared malloc heap, so this serialization is mandatory.

## Project structure

```
.
|-- Sources/                       # VoicePaste Swift sources
|   |-- main.swift                 # NSApplication bootstrap
|   |-- AppDelegate.swift          # NSStatusItem, NSPopover, hotkey
|   |-- CrashLog.swift             # ~/.config/voicepaste/crash.log (exceptions, signals, launches)
|   |-- AudioRecorder.swift        # @MainActor recorder + Phase-4 silence gate (fresh AVAudioEngine per recording)
|   |-- AudioFilter.swift          # 80 - 3400 Hz biquad bandpass
|   |-- VADService.swift           # FluidAudio Silero VAD wrapper (actor)
|   |-- SpeechSegmenter.swift      # probability hysteresis + hangover
|   |-- SpeakerEmbedder.swift      # FluidAudio WeSpeaker wrapper (actor)
|   |-- VoiceprintStore.swift      # voiceprints.json persistence + cosine match
|   |-- VoiceStore.swift           # @MainActor app state, transcription pipeline
|   |-- TranscriptionService.swift # Whisper HTTP client
|   |-- ProxyHTTP.swift            # proxy fallback for geo-blocked APIs
|   |-- ObjCShim/                  # @try/@catch bridge so AVFAudio NSExceptions become Swift errors
|   |-- PopoverView.swift          # SwiftUI popover (level meter, history, profiles)
|   |-- EnrollmentView.swift       # 3-clip enrollment sheet
|   `-- Config.swift               # ~/.config/voicepaste/config.json schema
|-- TempMonitor/                   # Separate Mac SMC temperature menu bar app
|   `-- Sources/                   #   (lives in this repo for convenience)
|-- docs/superpowers/plans/        # Implementation plans for each phase
|-- Package.swift                  # SPM manifest
|-- Info.plist                     # CFBundle... + NSMicrophoneUsageDescription
|-- launchd/                       # LaunchAgent template for `make install-agent`
|-- Makefile                       # build / install / redeploy / install-agent / clean
|-- config.example.json            # Template for ~/.config/voicepaste/config.json
|-- LICENSE                        # MIT
`-- README.md
```

`TempMonitor/` is a separate small SMC temperature menu bar app that lives alongside VoicePaste in this repo. It is independent of VoicePaste and has its own `Makefile` and `Package.swift`.

## Building from source

VoicePaste uses Swift Package Manager. The only third-party dependency is **FluidAudio**, pinned exactly to `0.12.4`:

```swift
.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.12.4")
```

Do NOT bump this version without re-testing speaker enrollment - the embedding API and CoreML model graph have changed across minor versions.

```bash
swift build -c release   # release-mode build
make install             # bundles into VoicePaste.app and codesigns ad-hoc
make redeploy            # install + restart any running instance
make install-agent       # install + LaunchAgent (autostart, restart after crash)
make clean               # removes .build/ and VoicePaste.app
```

`make install` uses ad-hoc codesigning (`codesign --force --sign -`). For App Store distribution you'd need a Developer ID; for personal use ad-hoc is fine.

## FAQ

### Can I use a local Whisper model instead?

Out of the box VoicePaste ships with three providers (OpenRouter / OpenAI / Groq). To target a local server speaking the OpenAI `/v1/audio/transcriptions` API (`whisper.cpp` server, [LocalAI](https://localai.io), [llama.cpp's whisper-server](https://github.com/ggerganov/whisper.cpp/tree/master/examples/server)), add a thin custom provider in `Sources/TranscriptionProvider.swift` (copy `OpenAIProvider`, change `baseURL`) and register it in `ProviderRegistry.all`. Local servers usually ignore the API key, so paste any non-empty placeholder when prompted.

### Does it work without an OpenRouter / OpenAI account?

Yes if you run a local server (see above). No if you want to use only the cloud - VoicePaste does not bundle a local Whisper.

### How accurate is speaker ID?

Cosine similarity 0.55 default threshold catches your voice reliably across normal variation but occasionally lets through similar-toned voices (sim 0.55 - 0.65). Phase 4 adds a "2 consecutive matches required" debounce so a single rogue match doesn't reset the silence timer. False reject rate is very low if you enroll three clips at your normal mic distance.

For higher precision (fewer false accepts at the cost of more false rejects), edit `voiceprints.json` and bump per-profile `threshold` to `0.65` or `0.7`. Or enroll a second "morning voice" / "hoarse voice" profile to widen acceptance without lowering the threshold.

### Can I use it in Russian?

Yes. Set `"language": "ru"` in config. VoicePaste was built and tested primarily on Russian dictation. The speaker embedder is language-independent (it learns voice timbre, not phonemes).

### Battery impact?

While idle: zero - the app sleeps between hotkey events. While recording: AVAudioEngine + Silero VAD running every 100 ms, plus a CoreML embedding every ~500 ms during speech. On Apple Silicon this is light - typically < 5% CPU on an M-series, with WeSpeaker running on the ANE rather than the CPU. Don't leave it recording for hours unattended.

### Can I dictate into apps that don't have a text field?

VoicePaste only puts text on the clipboard - it does not auto-paste. Your active app needs a text-input destination for `Cmd+V`. For dictating into voice-controlled apps, set up a Shortcuts / Karabiner action that paste-and-presses-Enter after `Cmd+V`.

## Acknowledgments

- [FluidAudio](https://github.com/FluidInference/FluidAudio) - Silero VAD + WeSpeaker CoreML wrappers
- [Silero VAD](https://github.com/snakers4/silero-vad) - voice activity detection
- [WeSpeaker](https://github.com/wenet-e2e/wespeaker) - speaker embedder model
- [OpenAI Whisper](https://github.com/openai/whisper) - speech-to-text model and API surface

## License

MIT - see [LICENSE](LICENSE).

Copyright (c) 2026 Alexey Samosadov
