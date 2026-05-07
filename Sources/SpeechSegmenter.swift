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
