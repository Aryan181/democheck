import Foundation
import Accelerate

struct ChirpGenerator {
    /// Generate a linear FMCW chirp waveform.
    /// Phase-continuous: φ(t) = 2π(f0·t + (f1-f0)·t²/(2T))
    static func generateChirp(
        startFreq: Float,
        endFreq: Float,
        sampleRate: Float,
        numSamples: Int,
        amplitude: Float = 1.0
    ) -> [Float] {
        var chirp = [Float](repeating: 0, count: numSamples)
        let T = Float(numSamples) / sampleRate
        let sweepRate = (endFreq - startFreq) / T

        for i in 0..<numSamples {
            let t = Float(i) / sampleRate
            let phase = 2.0 * Float.pi * (startFreq * t + 0.5 * sweepRate * t * t)
            chirp[i] = amplitude * sinf(phase)
        }
        return chirp
    }

    /// Build the full playback buffer: leading silence + 200 cycles of [chirp + guard]
    static func generatePlaybackBuffer(
        chirp: [Float],
        guardSamples: Int,
        cycles: Int,
        leadingSilenceSamples: Int
    ) -> [Float] {
        let cycleLength = chirp.count + guardSamples
        let totalSamples = leadingSilenceSamples + cycles * cycleLength
        var buffer = [Float](repeating: 0, count: totalSamples)

        for cycle in 0..<cycles {
            let offset = leadingSilenceSamples + cycle * cycleLength
            for i in 0..<chirp.count {
                buffer[offset + i] = chirp[i]
            }
            // guard interval is already 0
        }
        return buffer
    }
}
