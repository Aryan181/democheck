import Foundation
import Accelerate

struct DSP {

    // MARK: - FFT

    /// Compute magnitude-squared spectrum via real FFT (Accelerate vDSP).
    /// Input is zero-padded to `fftSize`. Returns fftSize/2 + 1 bins.
    static func fftMagnitudeSquared(signal: [Float], fftSize: Int) -> [Float] {
        let log2n = vDSP_Length(log2f(Float(fftSize)))

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Prepare input (zero-padded)
        var input = [Float](repeating: 0, count: fftSize)
        let copyCount = min(signal.count, fftSize)
        for i in 0..<copyCount {
            input[i] = signal[i]
        }

        // Pack into split complex
        let halfN = fftSize / 2
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(
                    realp: realBuf.baseAddress!,
                    imagp: imagBuf.baseAddress!
                )
                input.withUnsafeBufferPointer { inputBuf in
                    let inputPtr = UnsafeRawPointer(inputBuf.baseAddress!)
                        .assumingMemoryBound(to: DSPComplex.self)
                    vDSP_ctoz(inputPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        // Compute magnitude squared: realp^2 + imagp^2
        var magSq = [Float](repeating: 0, count: halfN)
        vDSP_vsq(realp, 1, &magSq, 1, vDSP_Length(halfN))
        var imagSq = [Float](repeating: 0, count: halfN)
        vDSP_vsq(imagp, 1, &imagSq, 1, vDSP_Length(halfN))
        vDSP_vadd(magSq, 1, imagSq, 1, &magSq, 1, vDSP_Length(halfN))

        // Scale (vDSP FFT includes a factor of 2)
        var scale: Float = 1.0 / Float(fftSize * fftSize)
        vDSP_vsmul(magSq, 1, &scale, &magSq, 1, vDSP_Length(halfN))

        return magSq
    }

    /// Average power in a frequency band (mean of mag-squared bins in range).
    static func bandPower(
        spectrum: [Float],
        sampleRate: Float,
        fftSize: Int,
        lowFreq: Float,
        highFreq: Float
    ) -> Float {
        let binWidth = sampleRate / Float(fftSize)
        let lowBin = Int(ceilf(lowFreq / binWidth))
        let highBin = min(Int(floorf(highFreq / binWidth)), spectrum.count - 1)

        guard highBin > lowBin else { return 1e-20 }

        var sum: Float = 0
        vDSP_sve(Array(spectrum[lowBin...highBin]), 1, &sum, vDSP_Length(highBin - lowBin + 1))
        return sum / Float(highBin - lowBin + 1)
    }

    // MARK: - Bandpass Filter

    /// FFT-based bandpass filter: zero bins outside [lowFreq, highFreq], then IFFT.
    /// Preserves phase. Returns array of same length as input (zero-padded tail truncated).
    static func bandpassFilter(
        signal: [Float],
        fftSize: Int,
        sampleRate: Float,
        lowFreq: Float,
        highFreq: Float
    ) -> [Float] {
        let log2n = vDSP_Length(log2f(Float(fftSize)))

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return Array(repeating: 0, count: signal.count)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Prepare input (zero-padded)
        var input = [Float](repeating: 0, count: fftSize)
        let copyCount = min(signal.count, fftSize)
        for i in 0..<copyCount {
            input[i] = signal[i]
        }

        // Pack into split complex
        let halfN = fftSize / 2
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(
                    realp: realBuf.baseAddress!,
                    imagp: imagBuf.baseAddress!
                )
                input.withUnsafeBufferPointer { inputBuf in
                    let inputPtr = UnsafeRawPointer(inputBuf.baseAddress!)
                        .assumingMemoryBound(to: DSPComplex.self)
                    vDSP_ctoz(inputPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        // Zero bins outside passband
        // DC is realp[0], Nyquist is imagp[0] in packed format
        let binWidth = sampleRate / Float(fftSize)
        let lowBin = Int(floor(lowFreq / binWidth))
        let highBin = Int(ceil(highFreq / binWidth))

        // Zero DC and Nyquist (both well outside 8-20 kHz)
        realp[0] = 0
        imagp[0] = 0

        // Zero bins below passband (bins 1..<lowBin)
        for i in 1..<min(lowBin, halfN) {
            realp[i] = 0
            imagp[i] = 0
        }

        // Zero bins above passband (bins highBin+1..<halfN)
        for i in min(highBin + 1, halfN)..<halfN {
            realp[i] = 0
            imagp[i] = 0
        }

        // Inverse FFT
        var output = [Float](repeating: 0, count: fftSize)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(
                    realp: realBuf.baseAddress!,
                    imagp: imagBuf.baseAddress!
                )
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Inverse))

                // Unpack split complex back to interleaved real
                output.withUnsafeMutableBufferPointer { outBuf in
                    let outPtr = UnsafeMutableRawPointer(outBuf.baseAddress!)
                        .assumingMemoryBound(to: DSPComplex.self)
                    vDSP_ztoc(&splitComplex, 1, outPtr, 2, vDSP_Length(halfN))
                }
            }
        }

        // Scale: forward FFT includes factor of 2, inverse doesn't normalize
        // Round-trip scale = 1 / (2 * fftSize)
        var scale = 1.0 / Float(2 * fftSize)
        vDSP_vsmul(output, 1, &scale, &output, 1, vDSP_Length(fftSize))

        return Array(output[0..<signal.count])
    }

    // MARK: - Cross-Correlation

    /// Cross-correlate signal with reference (sliding dot product).
    /// Returns correlation for lags 0..<(signal.count - reference.count + 1).
    /// vDSP_conv with positive stride computes C[n] = Σ A[n+k]·F[k], which is
    /// already cross-correlation. Do NOT reverse the reference.
    static func crossCorrelate(signal: [Float], reference: [Float]) -> [Float] {
        let sigLen = signal.count
        let refLen = reference.count
        guard sigLen >= refLen else { return [] }

        let outputLen = sigLen - refLen + 1
        var result = [Float](repeating: 0, count: outputLen)

        vDSP_conv(signal, 1, reference, 1, &result, 1,
                  vDSP_Length(outputLen), vDSP_Length(refLen))

        return result
    }

    // MARK: - Peak Finding

    /// Find the peak (max absolute value) in array starting from `startIndex`.
    /// Returns (index, value) where value is the absolute value at the peak.
    static func findPeak(in array: [Float], startIndex: Int = 0) -> (index: Int, value: Float) {
        guard startIndex < array.count else { return (0, 0) }

        // Take absolute value
        let slice = Array(array[startIndex...])
        var absSlice = [Float](repeating: 0, count: slice.count)
        vDSP_vabs(slice, 1, &absSlice, 1, vDSP_Length(slice.count))

        var maxVal: Float = 0
        var maxIdx: vDSP_Length = 0
        vDSP_maxvi(absSlice, 1, &maxVal, &maxIdx, vDSP_Length(absSlice.count))

        return (index: startIndex + Int(maxIdx), value: maxVal)
    }

    /// Measure the -3 dB width around a peak (where |value| drops below 0.707 * peak).
    static func measureWidth3dB(array: [Float], peakIndex: Int) -> Int {
        guard peakIndex >= 0, peakIndex < array.count else { return 0 }

        let peakVal = abs(array[peakIndex])
        let threshold = peakVal * 0.7071067811865476 // 1/sqrt(2)

        // Walk left
        var left = peakIndex
        while left > 0 && abs(array[left]) >= threshold {
            left -= 1
        }

        // Walk right
        var right = peakIndex
        while right < array.count - 1 && abs(array[right]) >= threshold {
            right += 1
        }

        return right - left
    }

    /// Timing-aligned least-squares subtraction of a calibration template.
    /// Searches ±10 samples for best alignment before computing α and subtracting.
    static func subtractCalibration(signal: [Float], calibration: [Float]) -> [Float] {
        let n = min(signal.count, calibration.count)
        guard n > 0 else { return signal }

        // 1. Find optimal alignment over ±maxShift samples
        let maxShift = 10
        var bestDot: Float = 0
        var bestShift = 0

        for shift in -maxShift...maxShift {
            let sigStart = max(0, shift)
            let calStart = max(0, -shift)
            let len = vDSP_Length(n - abs(shift))
            guard len > 0 else { continue }

            var dot: Float = 0
            signal.withUnsafeBufferPointer { sBuf in
                calibration.withUnsafeBufferPointer { cBuf in
                    vDSP_dotpr(sBuf.baseAddress! + sigStart, 1,
                               cBuf.baseAddress! + calStart, 1,
                               &dot, len)
                }
            }
            if dot > bestDot {    // max positive correlation
                bestDot = dot
                bestShift = shift
            }
        }

        // 2. Build shifted calibration array
        var alignedCal = [Float](repeating: 0, count: n)
        let srcStart = max(0, -bestShift)
        let dstStart = max(0, bestShift)
        let copyLen = n - abs(bestShift)
        for i in 0..<copyLen {
            alignedCal[dstStart + i] = calibration[srcStart + i]
        }

        // 3. Compute α = dot(signal, alignedCal) / dot(alignedCal, alignedCal)
        var dotSC: Float = 0
        vDSP_dotpr(signal, 1, alignedCal, 1, &dotSC, vDSP_Length(n))
        var dotCC: Float = 0
        vDSP_dotpr(alignedCal, 1, alignedCal, 1, &dotCC, vDSP_Length(n))

        guard dotCC > 1e-20 else { return signal }
        var alpha = dotSC / dotCC

        print("[cal-sub] bestShift=\(bestShift), α=\(alpha), dotSC=\(dotSC), dotCC=\(dotCC)")

        // 4. Subtract: result = signal − α·alignedCal
        var scaled = [Float](repeating: 0, count: n)
        vDSP_vsmul(alignedCal, 1, &alpha, &scaled, 1, vDSP_Length(n))

        var result = [Float](repeating: 0, count: signal.count)
        vDSP_vsub(scaled, 1, signal, 1, &result, 1, vDSP_Length(n))

        // Copy tail beyond calibration length
        for i in n..<signal.count {
            result[i] = signal[i]
        }

        return result
    }

    /// Compute the median of absolute values in an array.
    static func medianAbsolute(_ array: [Float]) -> Float {
        var absArray = [Float](repeating: 0, count: array.count)
        vDSP_vabs(array, 1, &absArray, 1, vDSP_Length(array.count))
        absArray.sort()
        let mid = absArray.count / 2
        if absArray.count % 2 == 0 {
            return (absArray[mid - 1] + absArray[mid]) / 2.0
        } else {
            return absArray[mid]
        }
    }
}
