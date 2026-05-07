# VoicePaste Speaker Identification (Multi-Profile) — Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-profile voice verification on top of Phase 1's VAD. The user enrolls one or more "voice profiles" (3 × 5-second clips per profile), each stored as a 256-d L2-normalized embedding. During recording, each VAD-detected speech segment is embedded and compared against ALL stored profiles via cosine similarity; segments that don't match any profile are dropped from the audio sent to Whisper.

**Architecture:** Reuse the [`FluidAudio`](https://github.com/FluidInference/FluidAudio) Swift Package already added in Phase 1 — its `DiarizerManager.extractEmbedding(_:)` returns a 256-d L2-normalized speaker embedding (WeSpeaker-CoreML, optimized for ANE). We persist profiles as JSON at `~/.config/voicepaste/voiceprints.json` via a new `VoiceprintStore`. A new `SpeakerEmbedder` wraps the diarizer and exposes `embed(samples:) async -> [Float]`. `AudioRecorder` is upgraded to track speech *segments* (start/end driven by VAD probability transitions); on stop, each segment is embedded, scored against profiles, and either kept or dropped before being concatenated and sent to the existing `TranscriptionService`. The popover gains a "Voice Profiles" section (list, add, delete) and history rows show per-segment match info with a "Should have passed?" online-learning button.

> **Important design pivot — please confirm before implementing:** The original spec proposed ECAPA-TDNN from SpeechBrain. Live research found that direct SpeechBrain → CoreML conversion is *known-difficult* (forward-arg signature mismatch, ModuleList indexing issues — see [speechbrain#1627](https://github.com/speechbrain/speechbrain/discussions/1627), [coremltools#765](https://github.com/apple/coremltools/issues/765)). Meanwhile, **FluidAudio already ships a CoreML-converted WeSpeaker embedder** with a public `extractEmbedding` API — same family of 256-d L2-normalized speaker embeddings, equivalent verification quality, zero conversion work, runs on ANE. This plan therefore uses WeSpeaker-via-FluidAudio. If you specifically need ECAPA, see the optional Task A1 at the end of this document for the conversion script — it's a multi-hour undertaking with non-trivial debugging.

**Tech Stack:** Swift 5.9+, AVFoundation, CoreML, FluidAudio, SwiftUI.

**Prerequisite:** Phase 1 (`2026-05-07-voicepaste-vad-phase1.md`) is complete and merged.

---

## File Structure

| Path | Status | Responsibility |
|---|---|---|
| `Sources/VoiceprintStore.swift` | **create** | Codable `Voiceprint { name, embedding, threshold, enrolledAt }`. Loads/saves `~/.config/voicepaste/voiceprints.json`. CRUD + `bestMatch(_:) -> (Voiceprint, Float)?`. |
| `Sources/SpeakerEmbedder.swift` | **create** | Wraps FluidAudio `DiarizerManager`. `embed(samples:sampleRate:) async throws -> [Float]` returns the 256-d L2-normalized vector. |
| `Sources/EnrollmentView.swift` | **create** | SwiftUI sheet: name field, three "Record 5 s" buttons with progress, computes mean embedding on finish, saves via `VoiceprintStore`. |
| `Sources/SpeechSegmenter.swift` | **create** | Buffers raw input audio into VAD-detected speech segments (start when prob≥thresh for ≥250 ms, end when prob<thresh for ≥500 ms). Returns `[(start: TimeInterval, end: TimeInterval, samples: [Float])]`. |
| `Sources/AudioRecorder.swift` | modify | Add segment-tracking on top of Phase 1 VAD; expose segments via delegate at stop time. |
| `Sources/VoiceStore.swift` | modify | Run speaker matching on segments at stop; record per-segment `match` info; concatenate kept segments to a new wav for Whisper. Online-learning hook for "Should have passed". |
| `Sources/PopoverView.swift` | modify | Add Voice Profiles section + Add/Delete buttons. Update history rows to show match badge + "Should have passed?" button on rejected segments. |
| `Sources/AppDelegate.swift` | modify (small) | Add an `@State` (well, weak ref) so the enrollment sheet can be presented modally from the popover. |
| `Sources/TranscriptionService.swift` | modify (small) | Add a `transcribe(samples: [Float], sampleRate: Double)` overload so we can send a freshly-built wav from kept segments without first dumping it via `AVAudioFile`. |

---

## Pre-flight

- [ ] Phase 1 complete: VAD popover bar visible during recording, console shows `[VoicePaste] VAD ready`.
- [ ] FluidAudio already in `Package.swift` (Phase 1 Task 1).
- [ ] `~/.config/voicepaste/config.json` exists.

```bash
test -f ~/.config/voicepaste/config.json && echo "config OK"
test -d /Users/alexey/MyHammerspoon/.build/checkouts/FluidAudio && echo "FluidAudio OK"
```

Expected: both lines print OK.

---

## Task 1 — `VoiceprintStore.swift`

**Files:** `/Users/alexey/MyHammerspoon/Sources/VoiceprintStore.swift` (**new file**)

- [ ] 1.1  Create the file with this exact content:

```swift
import Foundation

struct Voiceprint: Codable, Identifiable {
    let id: UUID
    var name: String
    /// 256-d L2-normalized embedding (WeSpeaker via FluidAudio).
    var embedding: [Float]
    /// Cosine threshold for accepting a match against this profile.
    /// Default 0.55 — tune per-profile via UI later.
    var threshold: Float
    var enrolledAt: Date

    init(id: UUID = UUID(), name: String, embedding: [Float],
         threshold: Float = 0.55, enrolledAt: Date = Date()) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.threshold = threshold
        self.enrolledAt = enrolledAt
    }
}

/// Persistent store for enrolled voice profiles.
final class VoiceprintStore: ObservableObject {
    @Published private(set) var profiles: [Voiceprint] = []

    static let storePath: URL = {
        Config.configDir.appendingPathComponent("voiceprints.json")
    }()

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: VoiceprintStore.storePath) else {
            profiles = []
            return
        }
        do {
            profiles = try JSONDecoder().decode([Voiceprint].self, from: data)
        } catch {
            print("[VoiceprintStore] decode error: \(error). Resetting.")
            profiles = []
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(
                at: Config.configDir, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(profiles)
            try data.write(to: VoiceprintStore.storePath)
        } catch {
            print("[VoiceprintStore] save error: \(error)")
        }
    }

    func add(_ profile: Voiceprint) {
        profiles.append(profile)
        save()
    }

    func remove(id: UUID) {
        profiles.removeAll { $0.id == id }
        save()
    }

    func update(_ profile: Voiceprint) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
            save()
        }
    }

    /// Returns the highest-similarity profile (regardless of threshold).
    /// Caller decides whether the score meets that profile's threshold.
    func bestMatch(_ embedding: [Float]) -> (profile: Voiceprint, similarity: Float)? {
        guard !profiles.isEmpty else { return nil }
        var best: (Voiceprint, Float) = (profiles[0], -.infinity)
        for p in profiles {
            let sim = VoiceprintStore.cosine(embedding, p.embedding)
            if sim > best.1 { best = (p, sim) }
        }
        return best
    }

    /// Returns true if the embedding matches ANY profile (sim ≥ that profile's threshold).
    func anyMatch(_ embedding: [Float]) -> (profile: Voiceprint, similarity: Float)? {
        var best: (Voiceprint, Float)?
        for p in profiles {
            let sim = VoiceprintStore.cosine(embedding, p.embedding)
            if sim >= p.threshold {
                if best == nil || sim > best!.1 { best = (p, sim) }
            }
        }
        return best
    }

    /// Append-and-renormalize: blend `newEmbedding` into the profile's stored
    /// embedding (running mean) and re-normalize. Used by "Should have passed?"
    /// online learning.
    func mergeIntoProfile(id: UUID, newEmbedding: [Float], weight: Float = 0.25) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        let old = profiles[idx].embedding
        guard old.count == newEmbedding.count else { return }
        var merged = [Float](repeating: 0, count: old.count)
        for i in 0..<old.count {
            merged[i] = (1 - weight) * old[i] + weight * newEmbedding[i]
        }
        profiles[idx].embedding = VoiceprintStore.l2Normalize(merged)
        save()
    }

    // MARK: - math

    /// Cosine similarity for L2-normalized vectors == dot product.
    /// Falls through to full cosine for non-normalized inputs.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : -1
    }

    static func l2Normalize(_ v: [Float]) -> [Float] {
        var n: Float = 0
        for x in v { n += x * x }
        n = n.squareRoot()
        guard n > 0 else { return v }
        return v.map { $0 / n }
    }

    /// Mean of N embeddings, then L2-normalized — used during enrollment.
    static func meanEmbedding(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var acc = [Float](repeating: 0, count: first.count)
        for emb in embeddings {
            guard emb.count == first.count else { continue }
            for i in 0..<first.count { acc[i] += emb[i] }
        }
        let n = Float(embeddings.count)
        for i in 0..<acc.count { acc[i] /= n }
        return l2Normalize(acc)
    }
}
```

- [ ] 1.2  Build:

```bash
cd /Users/alexey/MyHammerspoon && swift build -c release 2>&1 | tail -10
```

Expected: `Build complete!`.

---

## Task 2 — `SpeakerEmbedder.swift`

**Files:** `/Users/alexey/MyHammerspoon/Sources/SpeakerEmbedder.swift` (**new file**)

The FluidAudio public API for standalone speaker embedding is `DiarizerManager.extractEmbedding(_:)` (returns `[Float]`, dimension 256, already L2-normalized — see [Diarization Getting Started](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md)).

- [ ] 2.1  Create the file with this exact content:

```swift
import CoreML
import FluidAudio
import Foundation

/// Wraps FluidAudio's WeSpeaker-CoreML embedder via DiarizerManager.
/// Output: 256-d L2-normalized [Float]. Compare with cosine similarity
/// (== dot product, since vectors are unit-norm).
final class SpeakerEmbedder {
    static let targetSampleRate: Double = 16_000
    /// Minimum samples (1 s @ 16 kHz). Embeddings on shorter chunks are unreliable.
    static let minSamples: Int = 16_000

    private let diarizer: DiarizerManager

    init() async throws {
        // DiarizerManager loads pyannote segmentation + WeSpeaker embedding.
        // Extra cost over Phase 1's VadManager: ~14 MB of CoreML weights.
        self.diarizer = try await DiarizerManager()
    }

    /// Resample to 16 kHz mono, then run the WeSpeaker CoreML graph.
    /// Throws if `samples.count` < 1 s @ source rate.
    func embed(samples: [Float], sampleRate: Double) async throws -> [Float] {
        let resampled: [Float] = (sampleRate == SpeakerEmbedder.targetSampleRate)
            ? samples
            : samples.withUnsafeBufferPointer { ptr in
                VADService.resample(samples: ptr.baseAddress!, count: ptr.count,
                                    from: sampleRate, to: SpeakerEmbedder.targetSampleRate)
            }

        guard resampled.count >= SpeakerEmbedder.minSamples else {
            throw EmbedError.tooShort(samples: resampled.count)
        }

        // FluidAudio's extractEmbedding is the public API documented at
        // https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md
        let embedding = try diarizer.extractEmbedding(resampled)
        // Defensive re-normalize in case future FluidAudio versions change behavior.
        return VoiceprintStore.l2Normalize(embedding)
    }

    enum EmbedError: Error, LocalizedError {
        case tooShort(samples: Int)

        var errorDescription: String? {
            switch self {
            case .tooShort(let n):
                return "Speaker segment too short (\(n) samples; need ≥ \(SpeakerEmbedder.minSamples))."
            }
        }
    }
}
```

- [ ] 2.2  Build:

```bash
cd /Users/alexey/MyHammerspoon && swift build -c release 2>&1 | tail -10
```

If FluidAudio's `DiarizerManager()` initializer signature differs from what's shown above, the compiler will say `cannot find 'DiarizerManager' in scope` or `argument missing for parameter`. In that case, inspect the package source:

```bash
grep -rn "public final class DiarizerManager" /Users/alexey/MyHammerspoon/.build/checkouts/FluidAudio/Sources/ | head
grep -rn "extractEmbedding" /Users/alexey/MyHammerspoon/.build/checkouts/FluidAudio/Sources/ | head
```

Adjust the init call to match the discovered signature (the rest of the wrapper is independent of init shape). Common alternatives in current FluidAudio versions: `try await DiarizerManager.shared()`, `try await DiarizerManager(config: .default)`, `OfflineDiarizerManager()`.

Expected after fix: `Build complete!`.

---

## Task 3 — `SpeechSegmenter.swift`

**Files:** `/Users/alexey/MyHammerspoon/Sources/SpeechSegmenter.swift` (**new file**)

This is a small state machine that the recorder feeds (samples + per-chunk VAD probability) and that emits `Segment { startTime, endTime, samples }` once a stretch of speech is bracketed by silence.

- [ ] 3.1  Create the file with this exact content:

```swift
import Foundation

/// One bracketed speech segment within a recording. Times are seconds since
/// recording start. `samples` are at the recorder's native sample rate (NOT
/// the 16 kHz VAD rate).
struct SpeechSegment {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let samples: [Float]
    let sampleRate: Double
}

/// Streaming segmenter. Call `feed(samples:probability:timestamp:sampleRate:)`
/// from the audio tap. When `finish()` is called at stop time, returns all
/// completed segments plus any in-progress segment.
final class SpeechSegmenter {
    private let probThreshold: Float
    private let minSpeechSec: Double
    private let minSilenceSec: Double

    private var inSpeech = false
    private var segmentStart: TimeInterval = 0
    private var segmentSamples: [Float] = []
    private var lastSpeechTime: TimeInterval = 0
    private var lastSilenceStart: TimeInterval = 0

    private var completed: [SpeechSegment] = []
    private var sampleRate: Double = 0

    init(probThreshold: Float = 0.5,
         minSpeechSec: Double = 0.25,
         minSilenceSec: Double = 0.5) {
        self.probThreshold = probThreshold
        self.minSpeechSec = minSpeechSec
        self.minSilenceSec = minSilenceSec
    }

    /// `samples` is the raw mic chunk at the recorder's native rate.
    /// `probability` is the latest cached VAD speech probability.
    /// `timestamp` is seconds since recording start (end of this chunk).
    func feed(samples: [Float], probability: Float, timestamp: TimeInterval, sampleRate: Double) {
        self.sampleRate = sampleRate
        let isSpeech = probability >= probThreshold

        if isSpeech {
            if !inSpeech {
                // Speech begins
                inSpeech = true
                segmentStart = timestamp - Double(samples.count) / sampleRate
                segmentSamples.removeAll(keepingCapacity: true)
            }
            segmentSamples.append(contentsOf: samples)
            lastSpeechTime = timestamp
            lastSilenceStart = 0
        } else if inSpeech {
            // Trailing silence within an in-progress segment — keep
            // capturing samples (so we don't clip word endings) but
            // start the silence timer.
            segmentSamples.append(contentsOf: samples)
            if lastSilenceStart == 0 {
                lastSilenceStart = timestamp - Double(samples.count) / sampleRate
            }
            if timestamp - lastSilenceStart >= minSilenceSec {
                // Close the segment if it's long enough.
                let duration = lastSpeechTime - segmentStart
                if duration >= minSpeechSec {
                    completed.append(SpeechSegment(
                        startTime: segmentStart,
                        endTime: lastSpeechTime,
                        samples: segmentSamples,
                        sampleRate: sampleRate
                    ))
                }
                inSpeech = false
                segmentSamples.removeAll(keepingCapacity: true)
                lastSilenceStart = 0
            }
        }
        // Else: silence with no in-progress segment — drop samples.
    }

    /// Drain. Call once when recording stops.
    func finish() -> [SpeechSegment] {
        if inSpeech {
            let duration = lastSpeechTime - segmentStart
            if duration >= minSpeechSec {
                completed.append(SpeechSegment(
                    startTime: segmentStart,
                    endTime: lastSpeechTime,
                    samples: segmentSamples,
                    sampleRate: sampleRate
                ))
            }
        }
        let out = completed
        completed.removeAll()
        inSpeech = false
        segmentSamples.removeAll()
        return out
    }

    func reset() {
        inSpeech = false
        segmentSamples.removeAll()
        completed.removeAll()
        lastSilenceStart = 0
        lastSpeechTime = 0
        segmentStart = 0
    }
}
```

- [ ] 3.2  Build:

```bash
cd /Users/alexey/MyHammerspoon && swift build -c release 2>&1 | tail -5
```

Expected: `Build complete!`.

---

## Task 4 — Wire the segmenter into `AudioRecorder.swift`

**Files:** `/Users/alexey/MyHammerspoon/Sources/AudioRecorder.swift` (modify; this builds on the Phase 1 version)

- [ ] 4.1  Add segmenter ownership and a new delegate method. **Replace the protocol declaration** at the top (lines 4–7 in the Phase-1 file) with:

```swift
protocol AudioRecorderDelegate: AnyObject {
    func audioRecorderDidDetectSilence(_ recorder: AudioRecorder)
    func audioRecorderDidUpdateLevel(_ recorder: AudioRecorder, level: Float, speechProb: Float)
    /// Called once at stop time with all bracketed speech segments.
    /// (Empty if VAD or segmenter is disabled.)
    func audioRecorder(_ recorder: AudioRecorder, didFinishWithSegments segments: [SpeechSegment])
}
```

- [ ] 4.2  Add a `segmenter` property and start-time tracking. After the `private let vadService: VADService?` line (Phase 1), add:

```swift
    private let segmenter: SpeechSegmenter?
    private var recordingStartedAt: Date?
```

- [ ] 4.3  Update the `init(...)` to accept a segmenter. Replace the existing init with:

```swift
    init(silenceThreshold: Float = 0.01,
         silenceDuration: TimeInterval = 5.0,
         vadThreshold: Float = 0.5,
         vadService: VADService? = nil,
         segmenter: SpeechSegmenter? = nil) {
        self.silenceThreshold = silenceThreshold
        self.silenceDuration = silenceDuration
        self.vadThreshold = vadThreshold
        self.vadService = vadService
        self.segmenter = segmenter
    }
```

- [ ] 4.4  Reset start time in `startRecording()`. Right after `vadService?.reset()`, add:

```swift
        segmenter?.reset()
        recordingStartedAt = Date()
```

- [ ] 4.5  Modify `processBuffer(_:sampleRate:)`. Inside the `if let vad = vadService { ... }` block, after the `delegate?.audioRecorderDidUpdateLevel(...)` line and just before `self.checkActivity(...)`, add:

```swift
                    if let segmenter = self.segmenter, let started = self.recordingStartedAt {
                        let timestamp = Date().timeIntervalSince(started)
                        segmenter.feed(samples: snapshot, probability: prob,
                                       timestamp: timestamp, sampleRate: sampleRate)
                    }
```

- [ ] 4.6  Modify `stopRecording()`. Right before the `return fileURL` lines, drain the segmenter and notify the delegate (we still return the wav URL for backward compat with Phase 1 retry queue):

Replace the existing `stopRecording()` with:

```swift
    func stopRecording() -> URL? {
        guard isRecording else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        isRecording = false
        silenceStartTime = nil

        // Drain segmenter and broadcast.
        if let segmenter = segmenter {
            let segs = segmenter.finish()
            delegate?.audioRecorder(self, didFinishWithSegments: segs)
        } else {
            delegate?.audioRecorder(self, didFinishWithSegments: [])
        }

        guard let fileURL = currentFileURL,
              FileManager.default.fileExists(atPath: fileURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64,
              size > 1000 else {
            return nil
        }

        return fileURL
    }
```

- [ ] 4.7  Build — `VoiceStore` will fail to compile because it does not yet implement `audioRecorder(_:didFinishWithSegments:)`. That's expected; Task 5 fixes it.

```bash
cd /Users/alexey/MyHammerspoon && swift build -c release 2>&1 | tail -15
```

Expected error: "type 'VoiceStore' does not conform to protocol 'AudioRecorderDelegate'".

---

## Task 5 — Wire `VoiceStore.swift` to use embeddings + segments

**Files:** `/Users/alexey/MyHammerspoon/Sources/VoiceStore.swift` (modify)

- [ ] 5.1  Extend `TranscriptionEntry` with optional match info. **Replace** the struct declaration (currently lines 5–9):

```swift
struct TranscriptionEntry: Identifiable {
    let id = UUID()
    let date: Date
    let text: String
    /// Per-segment match info. nil for legacy/RMS-mode entries.
    var matches: [SegmentMatch] = []
}

struct SegmentMatch: Identifiable {
    let id = UUID()
    let startTime: TimeInterval
    let endTime: TimeInterval
    /// nil if rejected (no profile hit its threshold).
    var matchedProfileId: UUID?
    var matchedProfileName: String?
    var similarity: Float
    /// Cached embedding so "Should have passed?" can blend it in later.
    var embedding: [Float]
}
```

- [ ] 5.2  Add new state. After the existing `@Published` block, add:

```swift
    @Published var voiceprints: VoiceprintStore = VoiceprintStore()
    @Published var enrollmentInProgress: Bool = false

    private var speakerEmbedder: SpeakerEmbedder?
    private var segmenter: SpeechSegmenter = SpeechSegmenter(probThreshold: 0.5)
```

- [ ] 5.3  Update `loadConfig()` to also build the SpeakerEmbedder and pass the segmenter into the recorder. **Replace** the entire `loadConfig()` body from Phase 1 with:

```swift
    func loadConfig() {
        config = Config.load()
        transcriptionService = TranscriptionService(config: config)
        segmenter = SpeechSegmenter(probThreshold: config.vadThreshold)

        recorder = AudioRecorder(
            silenceThreshold: config.silenceThreshold,
            silenceDuration: config.silenceDuration,
            vadThreshold: config.vadThreshold,
            vadService: nil,
            segmenter: segmenter
        )
        recorder.delegate = self

        if config.vadEnabled {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let vad = try await VADService(threshold: self.config.vadThreshold)
                    let emb = try await SpeakerEmbedder()
                    await MainActor.run {
                        self.vadService = vad
                        self.speakerEmbedder = emb
                        self.recorder = AudioRecorder(
                            silenceThreshold: self.config.silenceThreshold,
                            silenceDuration: self.config.silenceDuration,
                            vadThreshold: self.config.vadThreshold,
                            vadService: vad,
                            segmenter: self.segmenter
                        )
                        self.recorder.delegate = self
                        print("[VoicePaste] VAD + Speaker embedder ready (profiles: \(self.voiceprints.profiles.count))")
                    }
                } catch {
                    await MainActor.run {
                        self.lastError = "Speaker model load failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
```

(Keep the `private var vadService: VADService?` line from Phase 1 — both `vadService` and `speakerEmbedder` live as ivars now.)

- [ ] 5.4  Add the new delegate method. After the existing `audioRecorderDidDetectSilence(...)` and `audioRecorderDidUpdateLevel(...)`, add:

```swift
    func audioRecorder(_ recorder: AudioRecorder, didFinishWithSegments segments: [SpeechSegment]) {
        // We get this BEFORE stopAndProcess() returns its wav URL to us.
        // Stash for the transcribe call.
        self.pendingSegments = segments
    }

    private var pendingSegments: [SpeechSegment] = []
```

- [ ] 5.5  Replace `stopAndProcess()` to use the segments instead of the raw wav. Find the existing implementation (Phase 1, around lines 90–105) and replace it with:

```swift
    func stopAndProcess() {
        durationTimer?.invalidate()
        durationTimer = nil

        let legacyURL = recorder.stopRecording() // also fires didFinishWithSegments

        guard !pendingSegments.isEmpty || legacyURL != nil else {
            state = .idle
            return
        }

        state = .processing
        audioLevel = 0
        speechProbability = 0
        silenceCountdown = 0
        NSSound(named: "Pop")?.play()

        let segs = pendingSegments
        pendingSegments = []

        if speakerEmbedder != nil && !voiceprints.profiles.isEmpty && !segs.isEmpty {
            // Speaker-verified path
            Task { [weak self] in
                await self?.processWithSpeakerVerification(segments: segs, fallbackURL: legacyURL)
            }
        } else if let legacyURL {
            // Phase-1-only path (no profiles enrolled yet, or no segments captured)
            transcribeWithRetry(fileURL: legacyURL, attempt: 1)
        } else {
            state = .idle
        }
    }

    private func processWithSpeakerVerification(segments: [SpeechSegment], fallbackURL: URL?) async {
        guard let embedder = speakerEmbedder else { return }

        var matches: [SegmentMatch] = []
        var keptSamples: [Float] = []
        var keptSampleRate: Double = 0

        for seg in segments {
            keptSampleRate = seg.sampleRate
            do {
                let emb = try await embedder.embed(
                    samples: seg.samples, sampleRate: seg.sampleRate
                )
                if let hit = voiceprints.anyMatch(emb) {
                    matches.append(SegmentMatch(
                        startTime: seg.startTime, endTime: seg.endTime,
                        matchedProfileId: hit.profile.id,
                        matchedProfileName: hit.profile.name,
                        similarity: hit.similarity,
                        embedding: emb
                    ))
                    keptSamples.append(contentsOf: seg.samples)
                } else {
                    let best = voiceprints.bestMatch(emb)
                    matches.append(SegmentMatch(
                        startTime: seg.startTime, endTime: seg.endTime,
                        matchedProfileId: nil,
                        matchedProfileName: best?.profile.name,
                        similarity: best?.similarity ?? -1,
                        embedding: emb
                    ))
                    print("[VoicePaste] segment \(seg.startTime)–\(seg.endTime)s rejected (best=\(best?.profile.name ?? "none") sim=\(best?.similarity ?? -1))")
                }
            } catch {
                print("[VoicePaste] embed error: \(error). Treating as rejected.")
                matches.append(SegmentMatch(
                    startTime: seg.startTime, endTime: seg.endTime,
                    matchedProfileId: nil, matchedProfileName: nil,
                    similarity: -1, embedding: []
                ))
            }
        }

        if keptSamples.isEmpty {
            await MainActor.run {
                self.state = .idle
                self.lastError = "All segments rejected (no profile matched). Re-enroll or lower threshold."
                NSSound(named: "Basso")?.play()
            }
            // Original wav stays on disk for manual replay.
            return
        }

        // Build a temp wav from kept samples and send to existing transcribe.
        let outURL = AudioRecorder.recordingsDir
            .appendingPathComponent("kept_\(Int(Date().timeIntervalSince1970)).wav")
        do {
            try VoiceStore.writeWav(samples: keptSamples, sampleRate: keptSampleRate, to: outURL)
        } catch {
            await MainActor.run {
                self.state = .idle
                self.lastError = "Failed to assemble verified audio: \(error.localizedDescription)"
            }
            return
        }

        await MainActor.run {
            self.transcribeWithRetry(fileURL: outURL, attempt: 1)
            // Stash matches so the next history insert picks them up.
            self.pendingMatches = matches
        }
    }

    private var pendingMatches: [SegmentMatch] = []

    /// PCM Float32 → 16-bit PCM mono WAV. Minimal in-process WAV writer so we
    /// don't depend on AVAudioFile's format detection on a non-recorded buffer.
    static func writeWav(samples: [Float], sampleRate: Double, to url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buf.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: samples.count)
            }
        }
        try file.write(from: buf)
    }
```

- [ ] 5.6  Modify the `transcribeWithRetry(fileURL:attempt:)` success branch so it picks up `pendingMatches`. Find the existing success block (where `history.insert(...)` is called) and replace the `history.insert(...)` line with:

```swift
                    let entry = TranscriptionEntry(
                        date: Date(), text: text, matches: self.pendingMatches
                    )
                    self.pendingMatches = []
                    history.insert(entry, at: 0)
```

- [ ] 5.7  Add an `import AVFoundation` at the top if not already present (the original file imports `Combine` and `AppKit` only — `AVAudioFormat` lives in AVFoundation).

```swift
import AVFoundation
```

- [ ] 5.8  Add the online-learning helper:

```swift
    /// "Should have passed?" — blend a rejected segment's embedding into the
    /// nearest existing profile.
    func acceptRejectedSegment(historyId: UUID, matchId: UUID) {
        guard let hIdx = history.firstIndex(where: { $0.id == historyId }) else { return }
        guard let m = history[hIdx].matches.first(where: { $0.id == matchId }) else { return }
        guard !m.embedding.isEmpty else { return }
        // If the best non-matching profile exists, blend into that one.
        // Else create a new profile if user already named one in UI? Simpler:
        // only blend if there is at least one profile.
        guard let best = voiceprints.bestMatch(m.embedding) else {
            lastError = "No profiles to blend into. Enroll a profile first."
            return
        }
        voiceprints.mergeIntoProfile(id: best.profile.id, newEmbedding: m.embedding)
        // Mutate history entry so badge changes from rejected to matched.
        history[hIdx].matches = history[hIdx].matches.map { mm in
            guard mm.id == matchId else { return mm }
            var copy = mm
            copy.matchedProfileId = best.profile.id
            copy.matchedProfileName = best.profile.name + " (online)"
            return copy
        }
    }
```

- [ ] 5.9  Build:

```bash
cd /Users/alexey/MyHammerspoon && swift build -c release 2>&1 | tail -15
```

Expected: `Build complete!`. Fix any small mismatches (e.g., capture lists, `Date` vs `TimeInterval` confusion) until clean.

---

## Task 6 — `EnrollmentView.swift`

**Files:** `/Users/alexey/MyHammerspoon/Sources/EnrollmentView.swift` (**new file**)

The enrollment sheet. UX: name field → three "Record (5 s)" buttons. Each tap captures 5 s of audio at 16 kHz, runs the embedder, displays a green checkmark when done. After all three are recorded, "Save profile" computes the mean and saves.

- [ ] 6.1  Create the file with this exact content:

```swift
import AVFoundation
import SwiftUI

struct EnrollmentView: View {
    @ObservedObject var store: VoiceStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var recorder: EnrollmentRecorder?
    @State private var capturedEmbeddings: [[Float]] = []
    @State private var isRecording: Bool = false
    @State private var recordingIndex: Int = -1
    @State private var countdown: Int = 0
    @State private var error: String?

    private let clipDuration: TimeInterval = 5.0
    private let clipsRequired: Int = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Voice Profile")
                .font(.title3).bold()

            VStack(alignment: .leading, spacing: 4) {
                Text("Profile name").font(.caption).foregroundColor(.secondary)
                TextField("e.g. Я обычный", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Record \(clipsRequired) clips of 5 seconds each. Speak naturally — say a different sentence in each clip.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                ForEach(0..<clipsRequired, id: \.self) { i in
                    HStack {
                        Image(systemName: i < capturedEmbeddings.count ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(i < capturedEmbeddings.count ? .green : .secondary)
                        Text("Clip \(i + 1)")
                            .frame(width: 60, alignment: .leading)
                        if recordingIndex == i {
                            ProgressView(value: Double(countdown), total: clipDuration)
                                .frame(maxWidth: .infinity)
                            Text("\(Int(clipDuration) - countdown)s")
                                .font(.caption).monospacedDigit()
                        } else {
                            Spacer()
                            Button(i < capturedEmbeddings.count ? "Re-record" : "Record (5 s)") {
                                Task { await recordClip(index: i) }
                            }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isRecording)
                        }
                    }
                }
            }

            if let error {
                Text(error).font(.caption).foregroundColor(.red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save profile") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(capturedEmbeddings.count < clipsRequired ||
                          name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func recordClip(index: Int) async {
        guard let embedder = store.speakerEmbedderForEnrollment else {
            error = "Speaker model not loaded yet. Wait a moment and retry."
            return
        }
        error = nil
        isRecording = true
        recordingIndex = index
        countdown = 0

        let rec = EnrollmentRecorder()
        recorder = rec
        do {
            try rec.start()
        } catch {
            self.error = "Recording failed: \(error.localizedDescription)"
            isRecording = false
            recordingIndex = -1
            return
        }

        // Drive the countdown UI on the main actor.
        for sec in 1...Int(clipDuration) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run { self.countdown = sec }
        }

        let (samples, sampleRate) = rec.stop()
        recorder = nil

        do {
            let emb = try await embedder.embed(samples: samples, sampleRate: sampleRate)
            await MainActor.run {
                if index < capturedEmbeddings.count {
                    capturedEmbeddings[index] = emb
                } else {
                    capturedEmbeddings.append(emb)
                }
                isRecording = false
                recordingIndex = -1
                countdown = 0
            }
        } catch {
            await MainActor.run {
                self.error = "Embed failed: \(error.localizedDescription)"
                self.isRecording = false
                self.recordingIndex = -1
            }
        }
    }

    private func save() {
        let mean = VoiceprintStore.meanEmbedding(capturedEmbeddings)
        guard !mean.isEmpty else {
            error = "Empty embedding."
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let profile = Voiceprint(name: trimmed, embedding: mean)
        store.voiceprints.add(profile)
        dismiss()
    }
}

/// Minimal one-shot recorder used only by EnrollmentView. Independent of
/// AudioRecorder so opening the sheet does not interfere with the main flow.
final class EnrollmentRecorder {
    private let engine = AVAudioEngine()
    private var captured: [Float] = []
    private var sampleRate: Double = 0

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "EnrollmentRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No input device"])
        }
        sampleRate = format.sampleRate
        captured.removeAll()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let ch = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let arr = Array(UnsafeBufferPointer(start: ch[0], count: frames))
            self.captured.append(contentsOf: arr)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() -> (samples: [Float], sampleRate: Double) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return (captured, sampleRate)
    }
}
```

- [ ] 6.2  Expose the embedder to the enrollment view by adding a computed property to `VoiceStore`. In `VoiceStore.swift`, add:

```swift
    var speakerEmbedderForEnrollment: SpeakerEmbedder? { speakerEmbedder }
```

- [ ] 6.3  Build:

```bash
cd /Users/alexey/MyHammerspoon && swift build -c release 2>&1 | tail -10
```

Expected: `Build complete!`.

---

## Task 7 — Modify `PopoverView.swift`

**Files:** `/Users/alexey/MyHammerspoon/Sources/PopoverView.swift` (modify)

- [ ] 7.1  Add a `@State` for the enrollment sheet and the Voice Profiles section. Insert into the struct top (right after `@ObservedObject var store: VoiceStore`):

```swift
    @State private var showEnrollment: Bool = false
```

- [ ] 7.2  Insert the Voice Profiles section into the body. **In the existing `body`**, add this block right above the `Divider()` that precedes `footerSection`:

```swift
            Divider()
            voiceProfilesSection
```

- [ ] 7.3  Add the new computed property at the bottom of the struct:

```swift
    private var voiceProfilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.wave.2")
                    .foregroundColor(.accentColor)
                Text("Voice Profiles (\(store.voiceprints.profiles.count))")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button {
                    showEnrollment = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            if store.voiceprints.profiles.isEmpty {
                Text("No profiles enrolled. All audio will be transcribed (no speaker filter).")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                ForEach(store.voiceprints.profiles) { profile in
                    HStack(spacing: 8) {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        Text(profile.name).font(.caption)
                        Spacer()
                        Text(String(format: "thr %.2f", profile.threshold))
                            .font(.caption2).foregroundColor(.secondary).monospacedDigit()
                        Button {
                            store.voiceprints.remove(id: profile.id)
                        } label: {
                            Image(systemName: "trash").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $showEnrollment) {
            EnrollmentView(store: store)
        }
    }
```

- [ ] 7.4  Update `historySection` to render match badges and the "Should have passed?" button. **Replace** the existing `historySection` with:

```swift
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(store.history.prefix(3)) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                        NSSound(named: "Tink")?.play()
                    }) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.text)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .foregroundColor(.primary)
                                Text(entry.date, style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)

                    // Match badges
                    if !entry.matches.isEmpty {
                        ForEach(entry.matches) { match in
                            HStack(spacing: 6) {
                                Image(systemName: match.matchedProfileId == nil
                                      ? "xmark.circle.fill" : "checkmark.circle.fill")
                                    .foregroundColor(match.matchedProfileId == nil ? .red : .green)
                                    .font(.caption2)
                                Text(matchLabel(match))
                                    .font(.caption2).foregroundColor(.secondary)
                                Spacer()
                                if match.matchedProfileId == nil && !match.embedding.isEmpty {
                                    Button("Should have passed?") {
                                        store.acceptRejectedSegment(historyId: entry.id, matchId: match.id)
                                    }
                                    .buttonStyle(.plain)
                                    .font(.caption2)
                                    .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.horizontal, 6)
                        }
                    }
                }
            }
        }
    }

    private func matchLabel(_ m: SegmentMatch) -> String {
        let dur = String(format: "%.1f–%.1fs", m.startTime, m.endTime)
        if let name = m.matchedProfileName, m.matchedProfileId != nil {
            return "\(dur)  matched: \(name) (\(String(format: "%.2f", m.similarity)))"
        }
        if let name = m.matchedProfileName {
            return "\(dur)  rejected — best: \(name) (\(String(format: "%.2f", m.similarity)))"
        }
        return "\(dur)  rejected"
    }
```

- [ ] 7.5  Build:

```bash
cd /Users/alexey/MyHammerspoon && swift build -c release 2>&1 | tail -10
```

Expected: `Build complete!`.

---

## Task 8 — Optional `TranscriptionService` overload

(Not strictly needed — `processWithSpeakerVerification` writes a wav and reuses `transcribeWithRetry(fileURL:)` — but if you want to skip the disk round-trip later, here is the in-memory variant. Skippable.)

**Files:** `/Users/alexey/MyHammerspoon/Sources/TranscriptionService.swift` (additive)

- [ ] 8.1  (Optional) Append after the existing `transcribe(fileURL:)`:

```swift
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vp_\(UUID().uuidString).wav")
        try VoiceStore.writeWav(samples: samples, sampleRate: sampleRate, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try await transcribe(fileURL: tmp)
    }
```

Mark Task 8 done either way.

---

## Task 9 — Build, deploy, smoke-test

- [ ] 9.1  Full rebuild + redeploy:

```bash
cd /Users/alexey/MyHammerspoon && make clean && make redeploy
```

- [ ] 9.2  In Console.app, filter for `VoicePaste`. Expected lines on launch:

```
[VoicePaste] Ready. Press Cmd+Shift+R or click menu bar icon.
[VoicePaste] VAD + Speaker embedder ready (profiles: 0)
```

- [ ] 9.3  **Test 1 — enrollment (normal voice):**
  1. Open the popover, click "+ Add" in Voice Profiles.
  2. Type "Я обычный", click "Record (5 s)" three times. Each clip: speak a different sentence ("раз, два, три, тестируем профиль").
  3. After three green checkmarks, click "Save profile".
  4. Verify `~/.config/voicepaste/voiceprints.json` exists and contains one entry with a 256-element `embedding` array.
  ```bash
  jq '.[0] | {name, threshold, embedding_len: (.embedding | length)}' ~/.config/voicepaste/voiceprints.json
  ```
  Expected: `{ "name": "Я обычный", "threshold": 0.55, "embedding_len": 256 }`.

- [ ] 9.4  **Test 2 — speak yourself:** Click Record, speak normally for 5 s, fall silent. After auto-stop the popover history shows "matched: Я обычный (0.7x)" and the transcription appears.

- [ ] 9.5  **Test 3 — second profile (hoarse voice):**
  1. Enroll a second profile "Я хриплый" the same way, but speak in a low/hoarse voice for the three clips.
  2. Now record yourself first normally, then a moment of breath, then in your hoarse voice. Expected: TWO segment badges, both green, matching the right profile each time.

- [ ] 9.6  **Test 4 — rejection:**
  1. Play a YouTube video where someone else is speaking (or a podcast).
  2. Click Record while the video plays. Wait 6 s. Auto-stop should fire (or you can press stop).
  3. The history entry shows red x badges with "rejected — best: Я обычный (0.3x)".
  4. **Important:** the Whisper transcription field for this entry should be empty or contain text from the *kept* segments only (in this scenario, none). Verify that the YouTube speaker's words did NOT end up in the transcript.

- [ ] 9.7  **Test 5 — online learning:**
  1. Trigger one rejection (Test 4 above gave you a rejected segment).
  2. Click "Should have passed?" on that badge.
  3. Confirm that profile's embedding shifts:
     ```bash
     jq '.[0].embedding[0:5]' ~/.config/voicepaste/voiceprints.json
     ```
     before and after — the values change slightly.
  4. Re-record the same kind of audio that was rejected and confirm it now matches.

- [ ] 9.8  **Test 6 — delete profile:** Click the trash icon on a profile. Verify it's removed from `voiceprints.json` immediately.

- [ ] 9.9  **Test 7 — empty profiles fallback:** Delete all profiles. Click Record, speak, stop. Verify the recording is transcribed normally (no filtering — empty-profile case bypasses speaker verification, just like Phase 1 alone).

- [ ] 9.10  **Test 8 — threshold tuning:** If matches are too strict (you yourself get rejected), edit `voiceprints.json` and lower `threshold` for your profile from 0.55 to 0.45. Restart VoicePaste. If false-accepts (other people pass), raise to 0.65.

---

## Task 10 — Verification before completion

- [ ] 10.1  Confirm binary still launches and ad-hoc signature is intact:

```bash
codesign --verify --deep --strict /Users/alexey/MyHammerspoon/VoicePaste.app && echo OK
du -sh /Users/alexey/MyHammerspoon/VoicePaste.app
```

Expected: `OK`. Size ~50–80 MB (added WeSpeaker CoreML weights ≈14 MB).

- [ ] 10.2  Acceptance criteria — all must hold:
  1. Hum a melody for 10 s while recording → recorder auto-stops in ≤ 6 s (Phase 1 still works).
  2. Speak own voice → matches profile, transcribes.
  3. Play someone else's recorded voice → all segments rejected, transcription is empty (or contains only your interjections).
  4. Enrolling two profiles for the same person (normal + hoarse) lets BOTH variants pass.
  5. "Should have passed?" actually mutates `voiceprints.json` and changes future behavior.

- [ ] 10.3  No leftover TODOs or unused properties. Search:

```bash
grep -nE "(TODO|FIXME)" /Users/alexey/MyHammerspoon/Sources/*.swift
```

Expected: empty output.

---

## Risks & follow-ups

- **DiarizerManager init signature drift:** FluidAudio's API surface is still pre-1.0. If `DiarizerManager()` (zero-arg) doesn't exist in the version pinned by Phase 1 (`from: 0.12.4`), see Task 2.2 fallback — inspect headers in `.build/checkouts/FluidAudio` and adapt.
- **Embedding dimension assumption:** This plan assumes 256 dims (per FluidAudio's internal docs). If actual output is different (e.g. 192 or 512), `VoiceprintStore.cosine` still works; nothing else cares about the constant.
- **Threshold default of 0.55:** Based on WeSpeaker / VoxCeleb operating points (typically 0.25–0.45 raw cosine for VoxCeleb-trained models, but FluidAudio's L2-normalized output often runs higher). The user should tune by trying real audio. If it's miscalibrated, false-rejects on his own voice will be the most-felt failure.
- **`hum + speak` mixed segment:** If the user hums while speaking, the segmenter glues them together. The embedder gets a noisy chunk and might fail to match. Mitigation: enroll a "humming + speaking" profile, or accept that humming briefly through speech is fine.
- **3rd-party voice in the same recording session as user voice:** Per-segment filtering handles this — user's segments pass, other person's segments are dropped. But Whisper sees a wav with gaps; if those segments overlap (cross-talk) they're glued in a single segment and either both pass or both drop. Acceptable for v1.
- **Online learning dilution:** Repeated "Should have passed?" with `weight=0.25` can drift the embedding far from original. Consider capping merges or storing per-profile merge count.

---

## Optional Task A1 — Self-converting ECAPA-TDNN (skip unless WeSpeaker is unsatisfactory)

If WeSpeaker quality is insufficient and the user wants ECAPA-TDNN specifically, here is the conversion recipe. This is documented for completeness but **not part of the default path** — it adds 2–4 hours of debugging work and depends on a Python venv with `coremltools` ≥ 7.0.

- [ ] A1.1  Create venv on macOS:

```bash
cd /Users/alexey/MyHammerspoon && python3.11 -m venv .venv-coreml
source .venv-coreml/bin/activate
pip install --upgrade pip
pip install "coremltools>=7.0" "torch>=2.1" "torchaudio>=2.1" "speechbrain>=1.0" "huggingface_hub"
```

- [ ] A1.2  Save this script as `/Users/alexey/MyHammerspoon/scripts/convert_ecapa.py`:

```python
"""
Convert SpeechBrain's ECAPA-TDNN speaker embedder to a CoreML mlpackage.

Wraps the encoder so the forward signature is just (mel_features) -> embedding,
sidestepping the length-arg trace error documented in
https://github.com/speechbrain/speechbrain/discussions/1627
"""
from pathlib import Path
import torch
import coremltools as ct
from speechbrain.inference.speaker import EncoderClassifier

OUT = Path("Resources/ecapa_tdnn.mlpackage")
OUT.parent.mkdir(parents=True, exist_ok=True)

clf = EncoderClassifier.from_hparams(
    source="speechbrain/spkrec-ecapa-voxceleb",
    savedir="pretrained_ecapa",
    run_opts={"device": "cpu"},
)
emb_model = clf.mods.embedding_model
emb_model.eval()

class Wrap(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m
    def forward(self, feats):           # feats: [B, T, 80]
        # SpeechBrain's ECAPA expects (feats, lengths). Pass lengths = ones.
        lengths = torch.ones(feats.shape[0])
        return self.m(feats, lengths)   # [B, 1, 192]

wrapped = Wrap(emb_model).eval()
example = torch.rand(1, 200, 80)        # 2 s of 80-mel features
traced = torch.jit.trace(wrapped, example)

mlmodel = ct.convert(
    traced,
    convert_to="mlprogram",
    inputs=[ct.TensorType(name="features",
                          shape=(1, ct.RangeDim(50, 600), 80),
                          dtype=ct.converters.mil.input_types.types.fp32)],
    outputs=[ct.TensorType(name="embedding",
                           dtype=ct.converters.mil.input_types.types.fp32)],
    compute_units=ct.ComputeUnit.CPU_AND_NE,
    minimum_deployment_target=ct.target.macOS14,
)
mlmodel.save(str(OUT))
print(f"Wrote {OUT}")
```

- [ ] A1.3  Run:

```bash
cd /Users/alexey/MyHammerspoon && source .venv-coreml/bin/activate && \
python scripts/convert_ecapa.py
```

Expected: `Wrote Resources/ecapa_tdnn.mlpackage` after ~30 s. Common failure modes:
  - `assert "PackedParams" in node.output().type().name()` → re-run with `coremltools==7.2` (downgrade).
  - `Convert IndexError on Res2Net` → in `coremltools.converters.mil`, set `compute_precision=ct.precision.FLOAT32`.

- [ ] A1.4  Compile to `.mlmodelc`:

```bash
xcrun coremlcompiler compile Resources/ecapa_tdnn.mlpackage Resources/
```

Produces `Resources/ecapa_tdnn.mlmodelc/`.

- [ ] A1.5  Update `Package.swift` to include the resource:

```swift
.executableTarget(
    name: "VoicePaste",
    dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
    path: "Sources",
    resources: [.copy("../Resources/ecapa_tdnn.mlmodelc")]
),
```

- [ ] A1.6  Update `Makefile`'s `install` target to also copy the mlmodelc into the app bundle:

```makefile
install: build
	mkdir -p "$(APP_DIR)/MacOS"
	mkdir -p "$(APP_DIR)/Resources"
	cp "$(BUILD_DIR)/$(BINARY_NAME)" "$(APP_DIR)/MacOS/$(BINARY_NAME)"
	cp Info.plist "$(APP_DIR)/Info.plist"
	cp -R Resources/ecapa_tdnn.mlmodelc "$(APP_DIR)/Resources/"
	codesign --force --sign - "$(APP_NAME)"
```

- [ ] A1.7  Implement `SpeakerEmbedder` against `MLModel` directly: load `Bundle.main.url(forResource: "ecapa_tdnn", withExtension: "mlmodelc")`, compute 80-mel features in Swift via `vDSP` or via FluidAudio's exposed FBANK frontend, run the model, L2-normalize the 192-d output. Mel-feature computation is the hardest part — about ~150 lines of `vDSP` code; see the [FluidAudio fbank source](https://github.com/FluidInference/FluidAudio) for reference.

This is significantly more work than the default WeSpeaker path. Recommended only if WeSpeaker EER on user's voice is unacceptable.

---

## Sources

- [FluidInference/FluidAudio (GitHub)](https://github.com/FluidInference/FluidAudio)
- [FluidAudio — Diarization Getting Started (extractEmbedding)](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md)
- [FluidAudio API.md (256-d L2-normalized embeddings)](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md)
- [pyannote/wespeaker-voxceleb-resnet34-LM (Hugging Face)](https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM)
- [SpeechBrain ECAPA-TDNN model card](https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb)
- [SpeechBrain discussion #1627 (CoreML conversion blockers)](https://github.com/speechbrain/speechbrain/discussions/1627)
- [coremltools — PyTorch Conversion Workflow](https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html)
- [Apple Developer — xcrun coremlcompiler usage](https://developer.apple.com/forums/thread/718136)
