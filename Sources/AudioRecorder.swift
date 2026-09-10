import AVFoundation
import Foundation
import ObjCShim

protocol AudioRecorderDelegate: AnyObject {
    func audioRecorderDidDetectSilence(_ recorder: AudioRecorder)
    func audioRecorderDidUpdateLevel(_ recorder: AudioRecorder, level: Float, speechProb: Float)
    func audioRecorder(_ recorder: AudioRecorder, didFinishWithSegments segments: [SpeechSegment])
    /// The audio hardware changed mid-recording (device swapped, sample rate
    /// changed, mic unplugged). The engine has already stopped itself, so no
    /// more audio will arrive; the delegate should finish the recording.
    func audioRecorderInputDidChange(_ recorder: AudioRecorder)
}

@MainActor
class AudioRecorder {
    /// Created fresh for every recording and torn down in `stopRecording`.
    ///
    /// A long-lived AVAudioEngine caches the input node's client format from
    /// its first run. On macOS 26 (Tahoe) the input node runs through a
    /// "DefaultDeviceAggregate" of mic + default output, whose sample rate
    /// follows the *output* device — so plugging headphones/AirPods/a display,
    /// or sleep/wake, flips it 44.1k <-> 48k even though the mic itself never
    /// changed. The cached format then goes stale and `installTap` raises an
    /// NSException — "Failed to create tap due to format mismatch" — which
    /// killed the app on the first ⌘⇧R after days of uptime. A new engine
    /// rebuilds the aggregate and re-reads the live format every time.
    private var engine: AVAudioEngine?
    private var configChangeObserver: NSObjectProtocol?
    private var audioFile: AVAudioFile?
    private(set) var isRecording = false
    private var silenceStartTime: Date?
    private let silenceThreshold: Float
    private let silenceDuration: TimeInterval
    private let vadThreshold: Float
    private let vadService: VADService?
    private let segmenter: SpeechSegmenter?
    private let audioFilter: AudioFilter?
    private var recordingStartedAt: Date?
    private var hasReceivedAudio = false
    private var currentFileURL: URL?

    private let liveEmbedder: SpeakerEmbedder?
    private weak var voiceprintStore: VoiceprintStore?
    private var rollingBuffer: [Float] = []
    private var rollingBufferSampleRate: Double = 0
    private var samplesSinceLastEmbed: Int = 0
    private var liveEmbedInFlight: Bool = false
    private(set) var lastUserSpeechAt: Date?
    private var liveEmbedCount: Int = 0
    private var lastDiagLogAt: Date?
    /// Number of consecutive matched embeds. Phase-4 requires >= 2 in a row
    /// before treating it as the user speaking — guards against rare false
    /// positives from non-user voices that briefly slip past the 0.55 threshold.
    private var consecutiveMatches: Int = 0
    private static let requiredConsecutiveMatches: Int = 2

    /// True when speaker-verified silence gating is active (live embedder set,
    /// store available, at least one profile enrolled). UI uses this to decide
    /// whether to display the Phase-4 silence age vs. the legacy VAD countdown.
    var isLiveSpeakerMode: Bool {
        liveEmbedder != nil && voiceprintStore != nil && !(voiceprintStore?.profiles.isEmpty ?? true)
    }

    /// Current age of the silence-timer in seconds, as computed by checkActivity.
    /// Returns 0 when the user is currently considered "speaking" (recent user
    /// match) or before any audio has been received. Returns the live age once
    /// `silenceStartTime` is engaged. This is the SAME value the auto-stop path
    /// uses, so the UI never disagrees with reality.
    var currentSilenceAge: TimeInterval {
        guard let start = silenceStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voicepaste")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("phase4.log")
    }()
    private static let logFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static func diagLog(_ msg: String) {
        let line = "\(logFmt.string(from: Date())) \(msg)\n"
        NSLog("%@", msg)
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    /// Resident set size in MB. Snapshot for memory-leak diagnostics — if
    /// RSS climbs unboundedly during a single recording session, we have a
    /// retained-Task or rolling-buffer leak.
    private static func currentRSSMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }

    weak var delegate: AudioRecorderDelegate?

    private static let rollingWindowSec: Double = 1.5
    private static let embedTriggerSec: Double = 0.5
    private static let minSamplesPerEmbed: Int = 16_000  // 1s @ 16 kHz

    nonisolated static let recordingsDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voicepaste/recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(silenceThreshold: Float = 0.01,
         silenceDuration: TimeInterval = 5.0,
         vadThreshold: Float = 0.5,
         vadService: VADService? = nil,
         segmenter: SpeechSegmenter? = nil,
         audioFilter: AudioFilter? = nil,
         liveEmbedder: SpeakerEmbedder? = nil,
         voiceprintStore: VoiceprintStore? = nil) {
        self.silenceThreshold = silenceThreshold
        self.silenceDuration = silenceDuration
        self.vadThreshold = vadThreshold
        self.vadService = vadService
        self.segmenter = segmenter
        self.audioFilter = audioFilter
        self.liveEmbedder = liveEmbedder
        self.voiceprintStore = voiceprintStore
    }

    func startRecording() throws {
        guard !isRecording else { return }

        // Each recording gets a unique timestamped file
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = AudioRecorder.recordingsDir
            .appendingPathComponent("rec_\(timestamp).wav")
        currentFileURL = fileURL

        // Fresh engine per recording — see the `engine` doc comment.
        tearDownEngine()
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        var recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        // AVFAudio requires the tap format on the input node to match the live
        // hardware format. On a fresh engine the two agree; if they ever
        // differ, trust the hardware side rather than the client-side cache.
        if hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
           hardwareFormat.sampleRate != recordingFormat.sampleRate
            || hardwareFormat.channelCount != recordingFormat.channelCount {
            AudioRecorder.diagLog("[Recorder] input node format \(recordingFormat) differs from hardware \(hardwareFormat); using hardware format")
            recordingFormat = hardwareFormat
        }

        let recordingFile = try AVAudioFile(
            forWriting: fileURL,
            settings: recordingFormat.settings
        )
        audioFile = recordingFile

        hasReceivedAudio = false
        silenceStartTime = nil

        // VADService is an actor — reset is async. Task inherits MainActor by
        // default; vadService access is fine, the reset() await crosses to the
        // VADService actor.
        Task { await self.vadService?.reset() }

        segmenter?.reset()
        audioFilter?.reset()
        recordingStartedAt = Date()

        rollingBuffer.removeAll()
        samplesSinceLastEmbed = 0
        liveEmbedInFlight = false
        lastUserSpeechAt = nil
        liveEmbedCount = 0
        lastDiagLogAt = nil
        consecutiveMatches = 0

        let profileCount = voiceprintStore?.profiles.count ?? -1
        let profileNames = (voiceprintStore?.profiles.map { "\($0.name)@\($0.threshold)" } ?? []).joined(separator: ",")
        AudioRecorder.diagLog("[Phase4] === startRecording === liveEmbedder=\(liveEmbedder != nil ? "set" : "nil") voiceprintStore=\(voiceprintStore != nil ? "set" : "nil") profiles=\(profileCount)[\(profileNames)] vadThreshold=\(vadThreshold) silenceDuration=\(silenceDuration) format=\(Int(recordingFormat.sampleRate))Hz/\(recordingFormat.channelCount)ch hw=\(Int(hardwareFormat.sampleRate))Hz/\(hardwareFormat.channelCount)ch")

        // Capture `recordingFile` directly so the audio-tap thread does not
        // need to read `self.audioFile` (which is MainActor-isolated).
        let sampleRate = recordingFormat.sampleRate
        let tapFormat = recordingFormat
        do {
            // AVFAudio reports tap/engine problems as NSExceptions, which Swift
            // cannot catch. Route the calls through the ObjC shim so a bad
            // state becomes a thrown error (shown in the UI) instead of a crash.
            try AudioRecorder.catchingObjCException {
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
                    // Apply filter in-place BEFORE writing and processing
                    if let filter = self?.audioFilter, let channelData = buffer.floatChannelData?[0] {
                        filter.apply(samples: channelData, count: Int(buffer.frameLength), sampleRate: sampleRate)
                    }
                    try? recordingFile.write(from: buffer)
                    self?.processBuffer(buffer, sampleRate: sampleRate)
                }
            }
            try AudioRecorder.catchingObjCException {
                engine.prepare()
                try engine.start()
            }
        } catch {
            // Leave nothing behind: a tap left on a stopped engine would make
            // the next installTap raise "tap already installed".
            inputNode.removeTap(onBus: 0)
            engine.stop()
            audioFile = nil
            AudioRecorder.diagLog("[Recorder] startRecording failed: \(error.localizedDescription)")
            throw error
        }

        self.engine = engine
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleConfigurationChange()
            }
        }
        isRecording = true
    }

    /// Posted by the engine when the input/output hardware changes while we
    /// are running (device swap, sample-rate change). The engine has already
    /// stopped and uninitialized itself, so audio has stopped flowing; finish
    /// the recording with what was captured instead of sitting in `.recording`
    /// with a dead engine.
    private func handleConfigurationChange() {
        guard isRecording else { return }
        AudioRecorder.diagLog("[Recorder] audio configuration changed mid-recording; stopping")
        delegate?.audioRecorderInputDidChange(self)
    }

    private func tearDownEngine() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Runs `body`, turning a raised NSException into a thrown Swift error.
    /// Swift errors thrown by `body` are rethrown unchanged.
    private static func catchingObjCException(_ body: () throws -> Void) throws {
        var swiftError: Error?
        var nsError: NSError?
        let ok = ObjCShimTry({
            do { try body() } catch { swiftError = error }
        }, &nsError)
        if let swiftError { throw swiftError }
        if !ok {
            throw RecorderError.audioEngineException(
                (nsError?.userInfo["exceptionReason"] as? String) ?? nsError?.localizedDescription ?? "unknown"
            )
        }
    }

    func stopRecording() -> URL? {
        guard isRecording else { return nil }

        tearDownEngine()
        audioFile = nil
        isRecording = false
        silenceStartTime = nil
        consecutiveMatches = 0

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

    /// Clean up old recordings, keep last N
    nonisolated static func cleanupOldRecordings(keep: Int = 50) {
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

    nonisolated private func processBuffer(_ buffer: AVAudioPCMBuffer, sampleRate: Double) {
        // File writing happens in the installTap closure with a directly
        // captured AVAudioFile reference — `self.audioFile` is MainActor and
        // would race here on the audio thread.

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
        if vadService != nil {
            // Snapshot samples on the audio thread so the Task does not
            // outlive the AVAudioPCMBuffer's storage. The actor's
            // process(samples:sampleRate:) takes [Float] now.
            let snapshot = Array(UnsafeBufferPointer(start: samples, count: frames))
            Task.detached { [weak self] in
                guard let self = self, let vad = self.vadService else { return }
                let prob = await vad.process(samples: snapshot, sampleRate: sampleRate)
                await MainActor.run {
                    guard self.isRecording else { return }
                    self.delegate?.audioRecorderDidUpdateLevel(self, level: rms, speechProb: prob)
                    if let segmenter = self.segmenter, let started = self.recordingStartedAt {
                        let timestamp = Date().timeIntervalSince(started)
                        segmenter.feed(samples: snapshot, probability: prob,
                                       timestamp: timestamp, sampleRate: sampleRate)
                    }

                    // Live speaker verification: embed voice in background to gate silence timer
                    if let embedder = self.liveEmbedder,
                       let store = self.voiceprintStore,
                       !store.profiles.isEmpty {
                        if prob >= self.vadThreshold {
                            self.rollingBuffer.append(contentsOf: snapshot)
                            self.rollingBufferSampleRate = sampleRate
                            let maxSamples = Int(AudioRecorder.rollingWindowSec * sampleRate)
                            if self.rollingBuffer.count > maxSamples {
                                self.rollingBuffer.removeFirst(self.rollingBuffer.count - maxSamples)
                            }
                            self.samplesSinceLastEmbed += snapshot.count
                        }

                        let triggerThreshold = Int(AudioRecorder.embedTriggerSec * sampleRate)
                        let minSamplesNative = Int(Double(AudioRecorder.minSamplesPerEmbed) * sampleRate / SpeakerEmbedder.targetSampleRate)
                        if !self.liveEmbedInFlight,
                           self.samplesSinceLastEmbed >= triggerThreshold,
                           self.rollingBuffer.count >= minSamplesNative {
                            self.samplesSinceLastEmbed = 0
                            self.liveEmbedInFlight = true
                            let bufSnapshot = self.rollingBuffer
                            let bufRate = self.rollingBufferSampleRate
                            let bufCount = bufSnapshot.count
                            Task.detached { [weak self] in
                                guard let self else { return }
                                do {
                                    let emb = try await embedder.embed(
                                        samples: bufSnapshot, sampleRate: bufRate
                                    )
                                    struct MatchResult {
                                        var matched: Bool
                                        var matchedName: String?
                                        var matchedSim: Float
                                        var bestName: String?
                                        var bestSim: Float
                                    }
                                    let result = await MainActor.run { () -> MatchResult in
                                        let hit = store.anyMatch(emb)
                                        let best = store.bestMatch(emb)
                                        return MatchResult(
                                            matched: hit != nil,
                                            matchedName: hit?.profile.name,
                                            matchedSim: hit?.similarity ?? -1,
                                            bestName: best?.profile.name,
                                            bestSim: best?.similarity ?? -1
                                        )
                                    }
                                    await MainActor.run {
                                        self.liveEmbedCount += 1
                                        if result.matched {
                                            self.consecutiveMatches += 1
                                            // Only treat as user-spoke once we've seen N consecutive
                                            // matches. Defends against rare false positives from
                                            // non-user voices that briefly slip past 0.55.
                                            if self.consecutiveMatches >= AudioRecorder.requiredConsecutiveMatches {
                                                self.lastUserSpeechAt = Date()
                                            }
                                        } else {
                                            self.consecutiveMatches = 0
                                        }
                                        AudioRecorder.diagLog("[Phase4] embed#\(self.liveEmbedCount) bufSamples=\(bufCount) bufRate=\(Int(bufRate)) matched=\(result.matched) sim=\(String(format: "%.3f", result.bestSim)) best=\(result.bestName ?? "nil") streak=\(self.consecutiveMatches)/\(AudioRecorder.requiredConsecutiveMatches) -> lastUserSpeechAt=\(self.lastUserSpeechAt.map { String(format: "%.2fs ago", Date().timeIntervalSince($0)) } ?? "nil")")
                                        self.liveEmbedInFlight = false
                                    }
                                } catch {
                                    await MainActor.run {
                                        AudioRecorder.diagLog("[Phase4] embed error: \(error)")
                                        self.liveEmbedInFlight = false
                                    }
                                }
                            }
                        }
                    }

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

        // Check if we're in live speaker verification mode
        let liveMode = (liveEmbedder != nil && voiceprintStore != nil && !(voiceprintStore?.profiles.isEmpty ?? true))

        if liveMode {
            // Silence timer resets ONLY when user's voice is detected via embedder.
            // Non-user voices (Alice, colleague, TV) do NOT reset the timer, so the
            // recording auto-stops 5s after the user goes quiet, regardless of who
            // else is talking.
            let now = Date()
            let secondsSinceStart = recordingStartedAt.map { now.timeIntervalSince($0) } ?? 0
            let secondsSinceUserSpeech: TimeInterval
            if let last = lastUserSpeechAt {
                secondsSinceUserSpeech = now.timeIntervalSince(last)
            } else {
                // No user-match yet. Reuse start-of-recording grace so the user
                // has time to begin speaking and trigger the first embedding.
                // After grace expires, this will be > 1.5 and the silence timer
                // engages. Grace is 3s to allow rolling buffer + first embed
                // (1s buffer fill + 0.5s trigger spacing + embed latency).
                secondsSinceUserSpeech = secondsSinceStart > 3.0 ? secondsSinceStart : 0
            }
            let hadRecentUserSpeech = secondsSinceUserSpeech < 1.5

            // hasReceivedAudio gates the silence timer from firing during the
            // initial moments before any audio arrives. In liveMode we flip it
            // true as soon as ANY audio is detected (raw VAD), so the silence
            // timer can engage even if the user's voice never matches.
            if isSpeech || rms >= silenceThreshold {
                hasReceivedAudio = true
            }

            if hadRecentUserSpeech {
                silenceStartTime = nil
            } else if hasReceivedAudio {
                if silenceStartTime == nil {
                    silenceStartTime = now
                } else if let start = silenceStartTime,
                          now.timeIntervalSince(start) >= silenceDuration {
                    AudioRecorder.diagLog("[Phase4] auto-stop: silence \(silenceDuration)s, secondsSinceUserSpeech=\(String(format: "%.2f", secondsSinceUserSpeech))")
                    delegate?.audioRecorderDidDetectSilence(self)
                }
            }

            // Throttled diagnostic — once per ~500ms
            if lastDiagLogAt == nil || now.timeIntervalSince(lastDiagLogAt!) > 0.5 {
                lastDiagLogAt = now
                let silAge = silenceStartTime.map { now.timeIntervalSince($0) } ?? -1
                AudioRecorder.diagLog("[Phase4] tick prob=\(String(format: "%.2f", speechProb)) sinceUserSpeech=\(String(format: "%.2f", secondsSinceUserSpeech)) recentUser=\(hadRecentUserSpeech) hasAudio=\(hasReceivedAudio) silAge=\(String(format: "%.2f", silAge)) inFlight=\(liveEmbedInFlight) bufSize=\(rollingBuffer.count) rss=\(String(format: "%.1f", AudioRecorder.currentRSSMB()))MB")
            }
        } else {
            // Phase 1 behavior: any VAD speech resets the timer
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
            // Throttled diagnostic for debug visibility into NON-liveMode (which
            // would itself indicate a bug because user has profiles enrolled).
            let now = Date()
            if lastDiagLogAt == nil || now.timeIntervalSince(lastDiagLogAt!) > 1.0 {
                lastDiagLogAt = now
                AudioRecorder.diagLog("[Phase4] tick liveMode=FALSE prob=\(String(format: "%.2f", speechProb)) embedderSet=\(liveEmbedder != nil) storeSet=\(voiceprintStore != nil) profiles=\(voiceprintStore?.profiles.count ?? -1)")
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
        /// AVFAudio raised an NSException (e.g. tap format mismatch after the
        /// microphone changed sample rate). Recoverable: just try again.
        case audioEngineException(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No audio input device available"
            case .audioEngineException(let reason):
                return "Audio engine error, press record again: \(reason)"
            }
        }
    }
}
