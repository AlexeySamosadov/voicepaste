import CoreML
import FluidAudio
import Foundation

/// Wraps FluidAudio's WeSpeaker-CoreML embedder.
///
/// IMPORTANT: This is an `actor`, not a class. The underlying
/// `DiarizerManager.extractSpeakerEmbedding` runs CoreML/ANE inference on a
/// shared model + Metal/ANE state. Concurrent calls (live per-500ms embed
/// from AudioRecorder + post-stop segment embedding from VoiceStore +
/// enrollment) corrupted the shared malloc heap (`BUG IN CLIENT OF
/// LIBMALLOC: memory corruption of free block` inside
/// `MTLCompilerFSCache::getElement` / `ANEMemoryUtils.createAlignedArray`).
/// Wrapping the embedder as an actor serializes every `embed(...)` call
/// across the whole app and eliminates the data race on the model.
///
/// Output: 256-d L2-normalized [Float]. Compare with cosine similarity
/// (== dot product, since vectors are unit-norm).
actor SpeakerEmbedder {
    static let targetSampleRate: Double = 16_000
    /// Minimum samples (1 s @ 16 kHz). Embeddings on shorter chunks are unreliable.
    static let minSamples: Int = 16_000

    private let diarizer: DiarizerManager

    init() async throws {
        // DiarizerManager's public init takes an optional DiarizerConfig.
        // We use default config. The init is synchronous, but we keep this async
        // for model loading.
        self.diarizer = DiarizerManager()

        // DiarizerManager requires manual initialization with DiarizerModels.
        // We load the models from HuggingFace if needed.
        let models = try await DiarizerModels.downloadIfNeeded()
        diarizer.initialize(models: models)
    }

    /// Resample to 16 kHz mono, then run the WeSpeaker CoreML graph.
    /// Throws if `samples.count` < 1 s @ source rate.
    func embed(samples: [Float], sampleRate: Double) throws -> [Float] {
        let resampled: [Float] = (sampleRate == SpeakerEmbedder.targetSampleRate)
            ? samples
            : VADService.resample(
                samples: samples,
                from: sampleRate,
                to: SpeakerEmbedder.targetSampleRate
            )

        guard resampled.count >= SpeakerEmbedder.minSamples else {
            throw EmbedError.tooShort(samples: resampled.count)
        }

        // DiarizerManager.extractSpeakerEmbedding is synchronous and returns
        // L2-normalized 256-d embedding. It takes any RandomAccessCollection<Float>.
        let embedding = try diarizer.extractSpeakerEmbedding(from: resampled)

        // Already L2-normalized by FluidAudio, but we normalize again to be safe.
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
