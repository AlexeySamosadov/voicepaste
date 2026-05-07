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
