import Accelerate
import Foundation

/// Stateful bandpass filter for the mic stream. Runs in-place on Float32
/// samples on the audio tap thread. Combines a 2-pole high-pass and a 2-pole
/// low-pass into one Direct-Form-II biquad cascade via vDSP.Biquad.
///
/// Default band 80–3400 Hz: kills HVAC rumble and street noise below 80,
/// kills hiss/ringing above 3400. Voice fundamentals (~85–255 Hz) and the
/// first three formants survive intact.
final class AudioFilter {
    private var biquad: vDSP.Biquad<Float>?
    private var sampleRate: Double = 0
    let highPassHz: Double
    let lowPassHz: Double

    init(highPassHz: Double = 80, lowPassHz: Double = 3400) {
        self.highPassHz = highPassHz
        self.lowPassHz = lowPassHz
    }

    /// Build (or rebuild) coefficients for a given sample rate.
    /// Called lazily on first sample, and again if the rate changes.
    private func rebuild(sampleRate: Double) {
        self.sampleRate = sampleRate
        // Two RBJ biquad sections: HPF then LPF, Q ≈ 0.707 (Butterworth).
        let coeffsHPF = AudioFilter.rbjHighPass(fs: sampleRate, fc: highPassHz, q: 0.707)
        let coeffsLPF = AudioFilter.rbjLowPass(fs: sampleRate, fc: lowPassHz, q: 0.707)
        let sections: [Double] = coeffsHPF + coeffsLPF
        // vDSP.Biquad takes [Double] coefficients; one channel; sectionCount = 2.
        self.biquad = vDSP.Biquad(
            coefficients: sections,
            channelCount: 1,
            sectionCount: 2,
            ofType: Float.self
        )
    }

    /// Filter the buffer in place. `samples` points to `count` Float32s.
    func apply(samples: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double) {
        if biquad == nil || self.sampleRate != sampleRate {
            rebuild(sampleRate: sampleRate)
        }
        guard var biquad = biquad else { return }
        let inBuf = UnsafeBufferPointer(start: samples, count: count)
        var out = [Float](repeating: 0, count: count)
        biquad.apply(input: inBuf, output: &out)
        // Persist filter state.
        self.biquad = biquad
        // Copy filtered samples back in-place.
        out.withUnsafeBufferPointer { src in
            samples.update(from: src.baseAddress!, count: count)
        }
    }

    func reset() {
        if sampleRate > 0 { rebuild(sampleRate: sampleRate) }
    }

    // MARK: - RBJ biquad coefficients
    // Returns 5 coefficients per section in the order vDSP.Biquad wants:
    // [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]   (numerator then denominator,
    // both already divided by a0; a0 itself is dropped).

    private static func rbjHighPass(fs: Double, fc: Double, q: Double) -> [Double] {
        let w0 = 2 * .pi * fc / fs
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2 * q)
        let b0 = (1 + cosW0) / 2
        let b1 = -(1 + cosW0)
        let b2 = (1 + cosW0) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosW0
        let a2 = 1 - alpha
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    private static func rbjLowPass(fs: Double, fc: Double, q: Double) -> [Double] {
        let w0 = 2 * .pi * fc / fs
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2 * q)
        let b0 = (1 - cosW0) / 2
        let b1 = 1 - cosW0
        let b2 = (1 - cosW0) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosW0
        let a2 = 1 - alpha
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }
}
