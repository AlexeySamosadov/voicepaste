import AppKit
import AVFoundation
import Foundation
import Combine

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

struct FailedRecording: Identifiable {
    let id = UUID()
    let date: Date
    let fileURL: URL
    var error: String
    var retryCount: Int = 0
    var isRetrying: Bool = false
}

@MainActor
class VoiceStore: ObservableObject, AudioRecorderDelegate {
    enum State: Equatable {
        case idle
        case recording
        case processing
    }

    @Published var state: State = .idle
    @Published var audioLevel: Float = 0
    @Published var speechProbability: Float = 0
    @Published var silenceCountdown: Double = 0
    @Published var recordingDuration: TimeInterval = 0
    @Published var history: [TranscriptionEntry] = []
    @Published var failedRecordings: [FailedRecording] = []
    @Published var lastError: String?
    @Published var voiceprints: VoiceprintStore = VoiceprintStore()
    @Published var enrollmentInProgress: Bool = false

    private var recorder: AudioRecorder!
    private var vadService: VADService?
    private var transcriptionService: TranscriptionService!
    private(set) var config: Config!
    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var speakerEmbedder: SpeakerEmbedder?
    private var segmenter: SpeechSegmenter = SpeechSegmenter(probThreshold: 0.5)
    private var pendingSegments: [SpeechSegment] = []
    private var pendingMatches: [SegmentMatch] = []

    private let maxAutoRetries = 3
    private let retryDelay: TimeInterval = 2.0

    init() {
        loadConfig()
        AudioRecorder.cleanupOldRecordings(keep: 50)
    }

    func loadConfig() {
        config = Config.load()
        transcriptionService = TranscriptionService(config: config)
        segmenter = SpeechSegmenter(probThreshold: config.vadThreshold)

        let filter: AudioFilter? = config.audioFilterEnabled ? AudioFilter() : nil

        recorder = AudioRecorder(
            silenceThreshold: config.silenceThreshold,
            silenceDuration: config.silenceDuration,
            vadThreshold: config.vadThreshold,
            vadService: nil,
            segmenter: segmenter,
            audioFilter: filter,
            liveEmbedder: nil,
            voiceprintStore: voiceprints
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
                        let filter: AudioFilter? = self.config.audioFilterEnabled ? AudioFilter() : nil
                        let liveEmb = self.config.liveSpeakerVerification ? emb : nil
                        self.recorder = AudioRecorder(
                            silenceThreshold: self.config.silenceThreshold,
                            silenceDuration: self.config.silenceDuration,
                            vadThreshold: self.config.vadThreshold,
                            vadService: vad,
                            segmenter: self.segmenter,
                            audioFilter: filter,
                            liveEmbedder: liveEmb,
                            voiceprintStore: self.voiceprints
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

    // MARK: - Actions

    func toggle() {
        switch state {
        case .idle: startRecording()
        case .recording: stopAndProcess()
        case .processing: break
        }
    }

    func startRecording() {
        guard !config.apiKey.isEmpty else { return }

        do {
            try recorder.startRecording()
            state = .recording
            audioLevel = 0
            silenceCountdown = 0
            lastError = nil
            recordingStartTime = Date()
            recordingDuration = 0
            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let start = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
            NSSound(named: "Tink")?.play()
        } catch {
            lastError = error.localizedDescription
        }
    }

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
            self.pendingMatches = matches
            self.transcribeWithRetry(fileURL: outURL, attempt: 1)
        }
    }

    /// PCM Float32 → 32-bit Float WAV. Minimal in-process WAV writer so we
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

    // MARK: - Transcription with auto-retry

    private func transcribeWithRetry(fileURL: URL, attempt: Int) {
        Task {
            do {
                let text = try await transcriptionService.transcribe(fileURL: fileURL)

                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)

                    let entry = TranscriptionEntry(
                        date: Date(), text: text, matches: self.pendingMatches
                    )
                    self.pendingMatches = []
                    history.insert(entry, at: 0)
                    if history.count > 20 { history = Array(history.prefix(20)) }

                    state = .idle
                    lastError = nil
                    NSSound(named: "Glass")?.play()

                    // Success — delete the audio file
                    try? FileManager.default.removeItem(at: fileURL)
                }
            } catch {
                await MainActor.run {
                    if attempt < maxAutoRetries {
                        // Auto-retry
                        lastError = "Retry \(attempt)/\(maxAutoRetries)... \(error.localizedDescription)"
                        print("[VoicePaste] Attempt \(attempt) failed, retrying in \(retryDelay)s...")

                        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                            self?.transcribeWithRetry(fileURL: fileURL, attempt: attempt + 1)
                        }
                    } else {
                        // All retries exhausted — save to failed list
                        state = .idle
                        lastError = error.localizedDescription
                        NSSound(named: "Basso")?.play()

                        failedRecordings.insert(FailedRecording(
                            date: Date(),
                            fileURL: fileURL,
                            error: error.localizedDescription,
                            retryCount: attempt
                        ), at: 0)

                        print("[VoicePaste] All \(maxAutoRetries) attempts failed. Audio saved: \(fileURL.lastPathComponent)")
                    }
                }
            }
        }
    }

    // MARK: - Manual retry for failed recordings

    func retryFailed(_ recording: FailedRecording) {
        guard let idx = failedRecordings.firstIndex(where: { $0.id == recording.id }) else { return }
        failedRecordings[idx].isRetrying = true

        Task {
            do {
                let text = try await transcriptionService.transcribe(fileURL: recording.fileURL)

                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)

                    history.insert(TranscriptionEntry(date: Date(), text: text), at: 0)
                    if history.count > 20 { history = Array(history.prefix(20)) }

                    failedRecordings.removeAll { $0.id == recording.id }
                    NSSound(named: "Glass")?.play()

                    // Success — now safe to delete
                    try? FileManager.default.removeItem(at: recording.fileURL)
                }
            } catch {
                await MainActor.run {
                    if let idx = failedRecordings.firstIndex(where: { $0.id == recording.id }) {
                        failedRecordings[idx].isRetrying = false
                        failedRecordings[idx].retryCount += 1
                        failedRecordings[idx].error = error.localizedDescription
                    }
                    NSSound(named: "Basso")?.play()
                }
            }
        }
    }

    func dismissFailed(_ recording: FailedRecording) {
        failedRecordings.removeAll { $0.id == recording.id }
        // Audio file stays on disk in ~/.config/voicepaste/recordings/
    }

    // MARK: - AudioRecorderDelegate

    func audioRecorderDidDetectSilence(_ recorder: AudioRecorder) {
        stopAndProcess()
    }

    func audioRecorderDidUpdateLevel(_ recorder: AudioRecorder, level: Float, speechProb: Float) {
        audioLevel = level
        speechProbability = speechProb

        // In live-speaker mode, the UI must mirror the actual auto-stop timer
        // (which counts time since last user-matched speech, NOT raw VAD).
        // Otherwise the UI shows 0.0s while the timer is silently approaching
        // 5s and auto-stop. Reuse the recorder's authoritative value.
        if recorder.isLiveSpeakerMode {
            silenceCountdown = min(recorder.currentSilenceAge, config.silenceDuration)
        } else {
            // Legacy VAD/RMS-based countdown for users without enrolled profiles.
            let isSilent: Bool
            if vadService != nil {
                isSilent = speechProb < config.vadThreshold
            } else {
                isSilent = level < config.silenceThreshold
            }
            if isSilent {
                silenceCountdown = min(silenceCountdown + 0.1, config.silenceDuration)
            } else {
                silenceCountdown = 0
            }
        }
    }

    func audioRecorder(_ recorder: AudioRecorder, didFinishWithSegments segments: [SpeechSegment]) {
        self.pendingSegments = segments
    }

    // MARK: - Helpers

    func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    /// "Should have passed?" — blend a rejected segment's embedding into the
    /// nearest existing profile.
    func acceptRejectedSegment(historyId: UUID, matchId: UUID) {
        guard let hIdx = history.firstIndex(where: { $0.id == historyId }) else { return }
        guard let m = history[hIdx].matches.first(where: { $0.id == matchId }) else { return }
        guard !m.embedding.isEmpty else { return }
        guard let best = voiceprints.bestMatch(m.embedding) else {
            lastError = "No profiles to blend into. Enroll a profile first."
            return
        }
        voiceprints.mergeIntoProfile(id: best.profile.id, newEmbedding: m.embedding)
        history[hIdx].matches = history[hIdx].matches.map { mm in
            guard mm.id == matchId else { return mm }
            var copy = mm
            copy.matchedProfileId = best.profile.id
            copy.matchedProfileName = best.profile.name + " (online)"
            return copy
        }
    }

    var speakerEmbedderForEnrollment: SpeakerEmbedder? { speakerEmbedder }
}
