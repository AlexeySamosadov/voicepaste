import AVFoundation
import FluidAudio
import Foundation

/// Wraps FluidAudio's public streaming Silero VAD.
/// As an actor, all mutable state is automatically serialized — safe to call
/// from audio-tap callbacks via `await`.
actor VADService {
    static let targetSampleRate: Double = 16_000
    static let chunkSize: Int = 4096  // 256 ms at 16 kHz

    private let manager: VadManager
    private var streamState: VadStreamState
    private var pending: [Float] = []
    private(set) var lastProbability: Float = 0.0

    init(threshold: Float) async throws {
        let cfg = VadConfig(
            defaultThreshold: threshold,
            debugMode: false,
            computeUnits: .cpuAndNeuralEngine
        )
        let mgr = try await VadManager(config: cfg)
        self.manager = mgr
        // VadManager is an actor; makeStreamState() is sync there but must be
        // accessed via await across the actor boundary.
        self.streamState = await mgr.makeStreamState()
    }

    func process(samples: [Float], sampleRate: Double) async -> Float {
        let resampled = VADService.resample(
            samples: samples,
            from: sampleRate,
            to: VADService.targetSampleRate
        )
        pending.append(contentsOf: resampled)

        while pending.count >= VADService.chunkSize {
            let chunk = Array(pending.prefix(VADService.chunkSize))
            pending.removeFirst(VADService.chunkSize)
            do {
                let result = try await manager.processStreamingChunk(
                    chunk,
                    state: streamState
                )
                streamState = result.state
                lastProbability = result.probability
            } catch {
                NSLog("[VADService] processStreamingChunk error: \(error)")
            }
        }
        return lastProbability
    }

    func reset() async {
        pending.removeAll(keepingCapacity: true)
        streamState = await manager.makeStreamState()
        lastProbability = 0.0
    }

    nonisolated static func resample(
        samples: [Float],
        from src: Double,
        to dst: Double
    ) -> [Float] {
        if src == dst { return samples }
        let count = samples.count
        guard count > 1 else { return [] }
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
