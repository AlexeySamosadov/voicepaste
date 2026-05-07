# VoicePaste VAD (Voice Activity Detection) — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the RMS-based silence detector in `Sources/AudioRecorder.swift` with Silero VAD inference so the 5-second auto-stop counts only frames where the user is actually speaking — music, fan noise, and other people's speech no longer keep the recorder armed.

**Architecture:** Bundle the [`FluidAudio`](https://github.com/FluidInference/FluidAudio) Swift Package (CoreML-backed Silero VAD running on Apple Neural Engine). Add a new `VADService` that wraps `VadManager` and exposes a per-chunk `probabilityOfSpeech([Float]) -> Float` API. `AudioRecorder` keeps its RMS calculation for the popover level meter (visual feedback) but switches its silence-decision logic to "frame is silent iff `vad.probabilityOfSpeech(samples) < threshold`". The 5-second timer accumulates only over VAD-silent frames.

**Tech Stack:** Swift 5.9+, AVFoundation, CoreML, FluidAudio (Silero VAD bundled), SwiftUI.

---

## File Structure

| Path | Status | Responsibility |
|---|---|---|
| `Package.swift` | modify | Add FluidAudio dependency. |
| `Sources/Config.swift` | modify | Add `vadEnabled: Bool` and `vadThreshold: Float` config knobs. |
| `Sources/VADService.swift` | **create** | Loads `VadManager`, exposes `func probabilityOfSpeech(samples: [Float], sampleRate: Double) -> Float`. Handles 16kHz resampling and 256ms chunking. |
| `Sources/AudioRecorder.swift` | modify | Replace RMS-only silence logic in `processBuffer`/`checkSilence` with VAD-driven decision. Keep RMS for level meter. |
| `Sources/VoiceStore.swift` | modify | Wire VAD threshold from config into the recorder; pass VAD-driven silence info to UI. |
| `Sources/PopoverView.swift` | modify (small) | Display "VAD: 0.83" in the level section so user can see speech probability live during recording. |
| `Makefile` | modify | Add `redeploy` convenience target running `make install` then `launchctl kickstart`. |

---

## Pre-flight: prerequisites

- [ ] Xcode 15+ installed (`xcode-select -p` returns a path under `Xcode.app`).
- [ ] `swift --version` ≥ 5.9.
- [ ] You have write access to `/Users/alexey/MyHammerspoon/`.
- [ ] App is currently installed and registered with launchd as `com.alexey.voicepaste` (you can verify with `launchctl list | grep voicepaste`). If not, that's fine — the manual run command in Task 8 still works.

Run this verification:

```bash
xcodebuild -version
swift --version
ls /Users/alexey/MyHammerspoon/VoicePaste.app/Contents/MacOS/VoicePaste
```

Expected output:

```
Xcode 15.x
Swift version 5.9 (or newer)
/Users/alexey/MyHammerspoon/VoicePaste.app/Contents/MacOS/VoicePaste
```

---

## Task 1 — Add the FluidAudio Swift package dependency

**Files:** `/Users/alexey/MyHammerspoon/Package.swift` (lines 1–13, full rewrite)

- [ ] 1.1  Replace the entire contents of `Package.swift` with:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoicePaste",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .executableTarget(
            name: "VoicePaste",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources"
        )
    ]
)
```

- [ ] 1.2  Resolve the package and verify it compiles cleanly (no Swift sources changed yet — just dependency fetch):

```bash
cd /Users/alexey/MyHammerspoon && swift package resolve
cd /Users/alexey/MyHammerspoon && swift build -c release 2>&1 | tail -20
```

Expected: `Build complete!` after package resolution. The CoreML model files come bundled inside the FluidAudio package — no extra resources to wire into our Makefile yet.

- [ ] 1.3  Commit checkpoint (no git repo here per env, so substitute with a `.snapshot` directory if you want to keep restore points; otherwise skip):

```bash
ls /Users/alexey/MyHammerspoon/.build/release/VoicePaste && echo "binary exists"
```

---

## Task 2 — Add VAD config knobs

**Files:** `/Users/alexey/MyHammerspoon/Sources/Config.swift` (lines 1–45, modify struct + defaults)

- [ ] 2.1  Open `Config.swift`. The current struct ends at line 44. Replace the `Config` struct body (lines 3–35) with the following — adds `vadEnabled` and `vadThreshold`, leaves all existing fields untouched and backward-compatible:

```swift
struct Config: Codable {
    var apiKey: String
    var baseURL: String
    var model: String
    var language: String?
    var silenceDuration: Double
    var silenceThreshold: Float
    var vadEnabled: Bool = true
    var vadThreshold: Float = 0.5

    static let configDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/voicepaste")
    }()

    static let configPath: URL = {
        configDir.appendingPathComponent("config.json")
    }()

    static func load() -> Config {
        guard let data = try? Data(contentsOf: configPath),
              let config = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config.defaultConfig
        }
        return config
    }

    static let defaultConfig = Config(
        apiKey: "",
        baseURL: "https://api.openai.com/v1",
        model: "whisper-1",
        language: nil,
        silenceDuration: 5.0,
        silenceThreshold: 0.01,
        vadEnabled: true,
        vadThreshold: 0.5
    )
```

(leave the closing `}` of the struct and the `save()` method as-is at lines 36–44.)

- [ ] 2.2  Default values mean: existing on-disk `~/.config/voicepaste/config.json` files (which lack the new keys) will still decode — Swift's `Codable` honors the in-struct defaults via the synthesized init. Verify by running:

```bash
cd /Users/alexey/MyHammerspoon && swift build -c release 2>&1 | grep -E "error|warning" | head
```

Expected: no errors. (You may see `warning: 'silenceThreshold' was never used` once we modify AudioRecorder later — ignore for now.)

- [ ] 2.3  If the user already has a `~/.config/voicepaste/config.json`, append the two new keys so the live config picks them up. Inspect first:

```bash
cat ~/.config/voicepaste/config.json 2>/dev/null || echo "no config yet"
```

If the file exists and is missing `vadEnabled`, write a one-liner using `jq` to add the defaults (skip if `jq` is not installed — Codable defaults will fill them in anyway):

```bash
test -f ~/.config/voicepaste/config.json && \
  jq '. + {vadEnabled: (.vadEnabled // true), vadThreshold: (.vadThreshold // 0.5)}' \
    ~/.config/voicepaste/config.json > ~/.config/voicepaste/config.json.tmp && \
  mv ~/.config/voicepaste/config.json.tmp ~/.config/voicepaste/config.json
```

---

## Task 3 — Create `VADService.swift`

**Files:** `/Users/alexey/MyHammerspoon/Sources/VADService.swift` (**new file**, full content below)

This service encapsulates `VadManager` from FluidAudio. The microphone delivers audio at the device's native sample rate (typically 48000 Hz) in arbitrary buffer sizes; Silero expects mono 16 kHz Float32 in 512-sample chunks (32 ms) but FluidAudio's `processChunk` accepts 4096-sample frames at 16 kHz (256 ms). We accumulate inbound samples until we have ≥ 4096 resampled samples, run inference, and cache the most recent `probability` for the recorder to read.

- [ ] 3.1  Create `/Users/alexey/MyHammerspoon/Sources/VADService.swift` with this exact content:

```swift
import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Wraps FluidAudio's CoreML Silero VAD.
/// Thread-safety: `process(samples:sampleRate:)` is called from the audio
/// tap thread; the cached `lastProbability` is read on the main queue. Both
/// access paths are protected by an internal serial queue.
final class VADService {
    // 16 kHz mono Float32 is what Silero VAD expects.
    static let targetSampleRate: Double = 16_000
    // FluidAudio's processChunk consumes 4096 samples = 256 ms.
    static let chunkSize: Int = 4096

    private let manager: VadManager
    private let queue = DispatchQueue(label: "voicepaste.vad", qos: .userInitiated)

    /// Buffer of resampled samples awaiting a full chunk.
    private var pending: [Float] = []
    /// Recurrent state passed between consecutive chunks.
    private var state: MLMultiArray?
    /// Cached probability of speech for the most recent chunk (0...1).
    private(set) var lastProbability: Float = 0.0

    /// Set up the model. Throws on first-load failure (missing CoreML bundle, etc.).
    init(threshold: Float) async throws {
        let config = VadConfig(
            defaultThreshold: threshold,
            debugMode: false,
            computeUnits: .cpuAndNeuralEngine
        )
        self.manager = try await VadManager(config: config)
    }

    /// Feed PCM samples at any sample rate. Returns the most recent
    /// per-chunk speech probability (the cached value if not enough
    /// samples have arrived yet to run a new inference).
    func process(samples: UnsafePointer<Float>, count: Int, sampleRate: Double) async -> Float {
        let resampled = VADService.resample(
            samples: samples, count: count,
            from: sampleRate, to: VADService.targetSampleRate
        )
        return await processResampled(resampled)
    }

    /// Reset between recordings.
    func reset() {
        queue.sync {
            pending.removeAll(keepingCapacity: true)
            state = nil
            lastProbability = 0.0
        }
    }

    // MARK: - private

    private func processResampled(_ samples: [Float]) async -> Float {
        // Append, then drain in chunkSize-sized increments.
        let chunks: [[Float]] = queue.sync {
            pending.append(contentsOf: samples)
            var out: [[Float]] = []
            while pending.count >= VADService.chunkSize {
                let chunk = Array(pending.prefix(VADService.chunkSize))
                pending.removeFirst(VADService.chunkSize)
                out.append(chunk)
            }
            return out
        }

        for chunk in chunks {
            do {
                let result = try await manager.processChunk(chunk, inputState: &state)
                queue.sync { self.lastProbability = result.probability }
            } catch {
                NSLog("[VADService] processChunk error: \(error)")
            }
        }
        return queue.sync { self.lastProbability }
    }

    /// Linear resampler. Adequate for VAD (Silero is robust to mild aliasing).
    /// If `from == to` returns a copy.
    static func resample(samples: UnsafePointer<Float>, count: Int,
                         from src: Double, to dst: Double) -> [Float] {
        if src == dst {
            return Array(UnsafeBufferPointer(start: samples, count: count))
        }
        let ratio = dst / src
        let newCount = Int(Double(count) * ratio)
        guard newCount > 1 else { return [] }
        var out = [Float](repeating: 0, count: newCount)
        let step = Double(count - 1) / Double(newCount - 1)
        for i in 0..<newCount {
            let srcIdx = Double(i) * step
            let i0 = Int(srcIdx)
            let i1 = min(i0 + 1, count - 1)
            let frac = Float(srcIdx - Double(i0))
            out[i] = samples[i0] * (1 - frac) + samples[i1] * frac
        }
        return out
    }
}
```

- [ ] 3.2  Build and confirm the new file compiles:

```bash
cd /Users/alexey/MyHammerspoon && swift build -c release 2>&1 | tail -20
```

Expected: `Build complete!`. If you see "no such module 'FluidAudio'", the package didn't resolve — re-run Task 1.

---

## Task 4 — Wire VAD into `AudioRecorder.swift`

**Files:** `/Users/alexey/MyHammerspoon/Sources/AudioRecorder.swift` (currently 158 lines, full rewrite)

Key changes vs. current code:
- The init takes an optional `VADService` and a `vadThreshold`.
- `processBuffer` still computes RMS for the level meter, then asynchronously asks the VAD whether the chunk is speech.
- `checkSilence` is replaced by `checkActivity(rms:speechProb:)` which now uses VAD as the silence gate; RMS is only used for the level meter callback. If VAD is disabled (`vadService == nil`) the old RMS gate is preserved as a fallback.

- [ ] 4.1  Replace the entire contents of `AudioRecorder.swift` with:

```swift
import AVFoundation
import Foundation

protocol AudioRecorderDelegate: AnyObject {
    func audioRecorderDidDetectSilence(_ recorder: AudioRecorder)
    func audioRecorderDidUpdateLevel(_ recorder: AudioRecorder, level: Float, speechProb: Float)
}

class AudioRecorder {
    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private(set) var isRecording = false
    private var silenceStartTime: Date?
    private let silenceThreshold: Float
    private let silenceDuration: TimeInterval
    private let vadThreshold: Float
    private let vadService: VADService?
    private var hasReceivedAudio = false
    private var currentFileURL: URL?

    weak var delegate: AudioRecorderDelegate?

    static let recordingsDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voicepaste/recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(silenceThreshold: Float = 0.01,
         silenceDuration: TimeInterval = 5.0,
         vadThreshold: Float = 0.5,
         vadService: VADService? = nil) {
        self.silenceThreshold = silenceThreshold
        self.silenceDuration = silenceDuration
        self.vadThreshold = vadThreshold
        self.vadService = vadService
    }

    func startRecording() throws {
        guard !isRecording else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = AudioRecorder.recordingsDir
            .appendingPathComponent("rec_\(timestamp).wav")
        currentFileURL = fileURL

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0 else {
            throw RecorderError.noInputDevice
        }

        audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: recordingFormat.settings
        )

        hasReceivedAudio = false
        silenceStartTime = nil
        vadService?.reset()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer, sampleRate: recordingFormat.sampleRate)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stopRecording() -> URL? {
        guard isRecording else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        isRecording = false
        silenceStartTime = nil

        guard let fileURL = currentFileURL,
              FileManager.default.fileExists(atPath: fileURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64,
              size > 1000 else {
            return nil
        }

        return fileURL
    }

    /// Clean up old recordings, keep last N
    static func cleanupOldRecordings(keep: Int = 50) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recordingsDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let sorted = files
            .filter { $0.pathExtension == "wav" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da > db
            }

        for file in sorted.dropFirst(keep) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer, sampleRate: Double) {
        do {
            try audioFile?.write(from: buffer)
        } catch {
            print("[AudioRecorder] Write error: \(error)")
        }

        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // RMS for the level meter (unchanged behavior)
        var sum: Float = 0
        let samples = channelData[0]
        for i in 0..<frames {
            let sample = samples[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frames))

        // Run VAD asynchronously — its lastProbability is what we trust.
        if let vad = vadService {
            // Snapshot samples on the audio thread so the Task does not
            // outlive the AVAudioPCMBuffer's storage.
            let snapshot = Array(UnsafeBufferPointer(start: samples, count: frames))
            Task.detached { [weak self] in
                let prob = await snapshot.withUnsafeBufferPointer { ptr -> Float in
                    await vad.process(samples: ptr.baseAddress!, count: ptr.count, sampleRate: sampleRate)
                }
                await MainActor.run {
                    guard let self = self, self.isRecording else { return }
                    self.delegate?.audioRecorderDidUpdateLevel(self, level: rms, speechProb: prob)
                    self.checkActivity(rms: rms, speechProb: prob)
                }
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isRecording else { return }
                self.delegate?.audioRecorderDidUpdateLevel(self, level: rms, speechProb: 0)
                // VAD disabled — fall back to original RMS gate.
                self.checkActivityRMSOnly(rms: rms)
            }
        }
    }

    private func checkActivity(rms: Float, speechProb: Float) {
        // VAD-driven gate. RMS is now ONLY used to ignore the very first
        // moments of silence before any sound has been recorded — once we've
        // seen a speech-positive frame, the 5s timer counts only frames whose
        // VAD prob < threshold.
        let isSpeech = speechProb >= vadThreshold

        if isSpeech {
            hasReceivedAudio = true
            silenceStartTime = nil
        } else if hasReceivedAudio {
            if silenceStartTime == nil {
                silenceStartTime = Date()
            } else if let start = silenceStartTime,
                      Date().timeIntervalSince(start) >= silenceDuration {
                delegate?.audioRecorderDidDetectSilence(self)
            }
        }
    }

    private func checkActivityRMSOnly(rms: Float) {
        if rms >= silenceThreshold {
            hasReceivedAudio = true
            silenceStartTime = nil
        } else if hasReceivedAudio {
            if silenceStartTime == nil {
                silenceStartTime = Date()
            } else if let start = silenceStartTime,
                      Date().timeIntervalSince(start) >= silenceDuration {
                delegate?.audioRecorderDidDetectSilence(self)
            }
        }
    }

    enum RecorderError: Error, LocalizedError {
        case noInputDevice

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No audio input device available"
            }
        }
    }
}
```

- [ ] 4.2  Build to surface mismatches in `VoiceStore.swift`'s `AudioRecorderDelegate` conformance — we changed the level-update signature:

```bash
cd /Users/alexey/MyHammerspoon && swift build -c release 2>&1 | tail -30
```

Expected: one error in `VoiceStore.swift`:
```
error: type 'VoiceStore' does not conform to protocol 'AudioRecorderDelegate'
```
That's intentional — Task 5 fixes it.

---

## Task 5 — Wire `VoiceStore.swift` to the new VAD-aware delegate signature

**Files:** `/Users/alexey/MyHammerspoon/Sources/VoiceStore.swift` (lines 27–57 and 199–213, modify)

- [ ] 5.1  Add a `@Published var speechProbability: Float = 0` after line 28 (the `audioLevel` publisher) so the popover can show the live VAD score:

Replace lines 27–32 (the `@Published` block) with:

```swift
    @Published var state: State = .idle
    @Published var audioLevel: Float = 0
    @Published var speechProbability: Float = 0
    @Published var silenceCountdown: Double = 0
    @Published var recordingDuration: TimeInterval = 0
    @Published var history: [TranscriptionEntry] = []
    @Published var failedRecordings: [FailedRecording] = []
    @Published var lastError: String?
```

- [ ] 5.2  Add a stored property for the VAD service. Insert after `private var recorder: AudioRecorder!` (currently line 35):

```swift
    private var vadService: VADService?
```

- [ ] 5.3  Modify `loadConfig()` (currently lines 49–57) to construct the VAD service asynchronously and re-build the recorder once it's ready. Replace the whole `loadConfig()` with:

```swift
    func loadConfig() {
        config = Config.load()
        transcriptionService = TranscriptionService(config: config)

        // Build a recorder immediately so toggling works even if VAD load is slow.
        // VAD will be plugged in once the model is loaded.
        recorder = AudioRecorder(
            silenceThreshold: config.silenceThreshold,
            silenceDuration: config.silenceDuration,
            vadThreshold: config.vadThreshold,
            vadService: nil
        )
        recorder.delegate = self

        if config.vadEnabled {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let svc = try await VADService(threshold: self.config.vadThreshold)
                    await MainActor.run {
                        self.vadService = svc
                        self.recorder = AudioRecorder(
                            silenceThreshold: self.config.silenceThreshold,
                            silenceDuration: self.config.silenceDuration,
                            vadThreshold: self.config.vadThreshold,
                            vadService: svc
                        )
                        self.recorder.delegate = self
                        print("[VoicePaste] VAD ready (threshold=\(self.config.vadThreshold))")
                    }
                } catch {
                    await MainActor.run {
                        self.lastError = "VAD load failed: \(error.localizedDescription) — falling back to RMS gate"
                        print("[VoicePaste] VAD load failed: \(error)")
                    }
                }
            }
        }
    }
```

- [ ] 5.4  Replace the existing `audioRecorderDidUpdateLevel` (currently lines 205–213) and add the new signature. Find the block:

```swift
    func audioRecorderDidUpdateLevel(_ recorder: AudioRecorder, level: Float) {
        audioLevel = level

        if level < config.silenceThreshold {
            silenceCountdown = min(silenceCountdown + 0.1, config.silenceDuration)
        } else {
            silenceCountdown = 0
        }
    }
```

Replace with:

```swift
    func audioRecorderDidUpdateLevel(_ recorder: AudioRecorder, level: Float, speechProb: Float) {
        audioLevel = level
        speechProbability = speechProb

        // Countdown ticks while VAD says no-speech (or, if VAD is disabled, while
        // RMS is below the legacy threshold).
        let isSilent = (vadService != nil)
            ? (speechProb < config.vadThreshold)
            : (level < config.silenceThreshold)

        if isSilent {
            silenceCountdown = min(silenceCountdown + 0.1, config.silenceDuration)
        } else {
            silenceCountdown = 0
        }
    }
```

- [ ] 5.5  Build and confirm clean:

```bash
cd /Users/alexey/MyHammerspoon && swift build -c release 2>&1 | tail -10
```

Expected: `Build complete!`.

---

## Task 6 — Show live VAD probability in the popover

**Files:** `/Users/alexey/MyHammerspoon/Sources/PopoverView.swift` (lines 120–160, the `levelSection` computed property)

- [ ] 6.1  Replace the `levelSection` computed property (currently lines 120–160) with this version, which adds a third row showing the live VAD probability:

```swift
    private var levelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Level")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.3f", store.audioLevel))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.08))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(levelColor)
                            .frame(width: geo.size.width * CGFloat(min(store.audioLevel * 10, 1.0)))
                    }
                }
                .frame(height: 8)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("VAD")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.2f", store.speechProbability))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(store.speechProbability >= store.config.vadThreshold ? .green : .secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.08))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(store.speechProbability >= store.config.vadThreshold ? Color.green : Color.gray)
                            .frame(width: geo.size.width * CGFloat(store.speechProbability))
                    }
                }
                .frame(height: 6)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Silence")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.1fs / %.0fs", store.silenceCountdown, store.config.silenceDuration))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(store.silenceCountdown > 3 ? .orange : .secondary)
                }
                ProgressView(value: store.silenceCountdown, total: store.config.silenceDuration)
                    .tint(store.silenceCountdown > 3 ? .orange : .blue)
            }
        }
    }
```

- [ ] 6.2  Build and confirm:

```bash
cd /Users/alexey/MyHammerspoon && swift build -c release 2>&1 | tail -5
```

Expected: `Build complete!`.

---

## Task 7 — Update Makefile with a redeploy target

**Files:** `/Users/alexey/MyHammerspoon/Makefile` (full rewrite)

- [ ] 7.1  Replace the entire Makefile with:

```makefile
.PHONY: build install run clean redeploy

BINARY_NAME = VoicePaste
APP_NAME = VoicePaste.app
BUILD_DIR = .build/release
APP_DIR = $(APP_NAME)/Contents

build:
	swift build -c release

install: build
	mkdir -p "$(APP_DIR)/MacOS"
	mkdir -p "$(APP_DIR)/Resources"
	cp "$(BUILD_DIR)/$(BINARY_NAME)" "$(APP_DIR)/MacOS/$(BINARY_NAME)"
	cp Info.plist "$(APP_DIR)/Info.plist"
	codesign --force --sign - "$(APP_NAME)"
	@echo ""
	@echo "Built $(APP_NAME). To use:"
	@echo "  open $(APP_NAME)"
	@echo "  # or move to /Applications, then make redeploy"

run: build
	"$(BUILD_DIR)/$(BINARY_NAME)"

redeploy: install
	-launchctl kickstart -k "gui/$$(id -u)/com.alexey.voicepaste" 2>/dev/null || true
	-pkill -x VoicePaste 2>/dev/null || true
	open "$(APP_NAME)"

clean:
	swift package clean
	rm -rf "$(APP_NAME)"
```

The `redeploy` target tries `launchctl kickstart` first (works if VoicePaste is registered as a launch agent) and falls back to `pkill && open`.

- [ ] 7.2  Verify the Makefile parses:

```bash
cd /Users/alexey/MyHammerspoon && make -n redeploy
```

Expected: prints commands; no syntax errors.

---

## Task 8 — Build, deploy, and run smoke tests

- [ ] 8.1  Full rebuild + redeploy:

```bash
cd /Users/alexey/MyHammerspoon && make clean && make redeploy
```

Expected output ends with:
```
Built VoicePaste.app. ...
```
and the menu-bar icon (mic) reappears within ~3 seconds.

- [ ] 8.2  In Console.app, filter for `VoicePaste` and verify you see (at app start):

```
[VoicePaste] Ready. Press Cmd+Shift+R or click menu bar icon.
[VoicePaste] VAD ready (threshold=0.5)
```

If you see "VAD load failed" instead, the FluidAudio CoreML bundle didn't download — try `make clean && swift package resolve && make redeploy`.

- [ ] 8.3  **Smoke test 1 — silence:** Click the menu-bar icon, click "Start Recording", do nothing for 6 seconds. Verify:
  - Level meter wiggles slightly with mic noise.
  - VAD bar stays gray (probability < 0.5).
  - Silence countdown reaches 5.0s and the recorder auto-stops within ~5.5s of pressing record.

- [ ] 8.4  **Smoke test 2 — humming/music (the original bug):** Start recording, then **hum a melody continuously** for 10 seconds (or play a music YouTube video). Verify:
  - Level meter shows steady audio.
  - VAD bar **stays gray** or oscillates below 0.5 most of the time.
  - Silence countdown still reaches 5.0s and the recording auto-stops within ~5–6 seconds.
  - Without VAD this would have held the recorder open indefinitely — that was the bug.

- [ ] 8.5  **Smoke test 3 — speech:** Start recording, speak naturally ("один, два, три, тест VAD") for 5 seconds, then stay quiet for 6 seconds. Verify:
  - VAD bar turns green during speech (probability ≥ 0.5).
  - Silence countdown resets while you speak.
  - Auto-stop fires ~5s after you fall silent.
  - Whisper transcription appears in the popover.

- [ ] 8.6  **Smoke test 4 — speech with background music:** Start recording with music playing, speak for 5 seconds, fall silent (music still playing). Verify:
  - VAD bar turns green during speech, drops back to gray when you stop speaking even though music continues.
  - Auto-stop fires ~5s after your last spoken word.
  - This is the headline win: silence detection now ignores non-speech audio.

- [ ] 8.7  **Smoke test 5 — VAD disabled fallback:** Edit `~/.config/voicepaste/config.json`, set `"vadEnabled": false`, save. Click "Quit" in popover and `open VoicePaste.app` again. Confirm the popover does not show the green "VAD" bar (it does still appear because we always render the section — it just stays at 0.00 and gray). Repeat the silence test — the original RMS gate should still trigger auto-stop within 5s of true quiet. Then set `"vadEnabled": true` again and re-deploy.

- [ ] 8.8  **Threshold tuning (optional):** If smoke test 4 fails to auto-stop because background music registers as speech, raise the threshold to `0.7` in `~/.config/voicepaste/config.json` and restart VoicePaste. If it auto-stops mid-sentence, lower it to `0.35`. Document the chosen value in the user's note.

---

## Task 9 — Verification before completion

- [ ] 9.1  Inspect the binary size — FluidAudio adds ~6 MB of CoreML model weights:

```bash
du -sh /Users/alexey/MyHammerspoon/VoicePaste.app
```

Expected: 30–50 MB (was ~5 MB before).

- [ ] 9.2  Confirm the `.app` is signed (ad-hoc):

```bash
codesign --verify --deep --strict /Users/alexey/MyHammerspoon/VoicePaste.app && echo OK
```

Expected: `OK`.

- [ ] 9.3  Run the binary directly and watch for runtime errors during a 30-second recording session that includes humming, speech, and silence:

```bash
/Users/alexey/MyHammerspoon/VoicePaste.app/Contents/MacOS/VoicePaste
```

Expected: no `EXC_BAD_ACCESS`, no FluidAudio "model not found" errors. Press Ctrl+C to stop.

- [ ] 9.4  Acceptance criterion: humming a melody for 10s while recording does NOT keep the recorder armed past the 5s silence window. If this holds, Phase 1 is done.

---

## Risks & follow-ups

- **First-run model download:** `VadManager(config:)` may download a CoreML bundle from Hugging Face on first run. If the user is offline, the first launch after `make clean` will fail. Document the network requirement.
- **VAD latency:** Each 4096-sample chunk runs CoreML inference. On Apple Silicon this is sub-millisecond on ANE; on Intel Macs it could be 5–20 ms. The async dispatch in `processBuffer` means audio capture is not blocked, but the `silenceCountdown` UI will lag by one or two chunks (~500 ms). Acceptable for a 5 s window.
- **Threshold lives in plain JSON:** No UI knob. If the user complains about over/under triggering, Phase 2 will already be touching the popover and we can add a slider then.

---

## Final commit checkpoint

(There's no git repo per env, so this is a notional "save".)

```bash
cd /Users/alexey/MyHammerspoon && du -sh .build VoicePaste.app && date
```

Done — Phase 1 complete.

---

## Sources

- [FluidInference/FluidAudio (GitHub)](https://github.com/FluidInference/FluidAudio)
- [FluidInference/silero-vad-coreml (Hugging Face)](https://huggingface.co/FluidInference/silero-vad-coreml)
- [FluidAudio API.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md)
- [FluidAudio on Swift Package Index](https://swiftpackageindex.com/FluidInference/FluidAudio)
- [coremltools — PyTorch Conversion Workflow](https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html)
- [Apple Developer — CoreML Off-Device Compilation](https://developer.apple.com/forums/thread/718136)
