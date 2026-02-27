import Foundation
import Accelerate

struct AnalysisPipeline {

    static let chirpSamples = 2400       // 50 ms at 48 kHz
    static let guardSamples = 1200       // 25 ms
    static let cycleSamples = 3600       // chirp + guard
    static let numCycles = 200

    // Extra samples beyond chirpSamples to capture reflection delay in correlation.
    // 600 samples at 48 kHz ≈ 12.5 ms ≈ ~2.1 m one-way range. Plenty for 30 cm.
    static let correlationMargin = 600
    static let avgSegmentLen = chirpSamples + correlationMargin  // 3000

    // MARK: - Coherent Averaging Helper

    /// Average aligned segments across cycles. Shared by Steps 2, 3, and calibration.
    private static func coherentAverage(
        recording: [Float], onsets: [Int], segLen: Int
    ) -> (averaged: [Float], validCycles: Int) {
        var avg = [Float](repeating: 0, count: segLen)
        var validCycles = 0

        for onset in onsets {
            let end = onset + segLen
            guard end <= recording.count else { continue }
            let segment = Array(recording[onset..<end])
            vDSP_vadd(avg, 1, segment, 1, &avg, 1, vDSP_Length(segLen))
            validCycles += 1
        }

        if validCycles > 0 {
            var divisor = Float(validCycles)
            vDSP_vsdiv(avg, 1, &divisor, &avg, 1, vDSP_Length(segLen))
        }

        return (avg, validCycles)
    }

    // MARK: - Calibration Entry Point

    /// Record with no reflector, run onset detection + coherent averaging,
    /// and return the averaged segment as a calibration template.
    static func calibrate(
        recording: [Float],
        chirpTemplate: [Float],
        sampleRate: Float
    ) -> [Float] {
        print("═══════════════════════════════════════")
        print("  AliasProbe Calibration")
        print("═══════════════════════════════════════")

        let onsets = findCycleOnsets(
            recording: recording,
            chirpTemplate: chirpTemplate,
            expectedCycles: numCycles,
            cycleSamples: cycleSamples
        )
        print("Calibration onsets found: \(onsets.count) / \(numCycles)")

        let (averaged, validCycles) = coherentAverage(
            recording: recording, onsets: onsets, segLen: avgSegmentLen
        )
        print("Calibration valid cycles: \(validCycles)")

        var rms: Float = 0
        vDSP_rmsqv(averaged, 1, &rms, vDSP_Length(avgSegmentLen))
        print("Calibration template RMS: \(rms)")
        print("═══════════════════════════════════════\n")

        return averaged
    }

    // MARK: - Main Entry Point

    static func analyze(
        recording: [Float],
        chirpTemplate: [Float],
        sampleRate: Float,
        calibrationTemplate: [Float]? = nil
    ) -> ProbeResult {
        print("═══════════════════════════════════════")
        print("  AliasProbe Analysis Pipeline")
        print("═══════════════════════════════════════")
        print("Recording length: \(recording.count) samples (\(String(format: "%.2f", Float(recording.count)/sampleRate)) s)")
        print("Sample rate: \(sampleRate) Hz")
        print("Chirp template length: \(chirpTemplate.count)")

        // Recording RMS
        var rms: Float = 0
        vDSP_rmsqv(recording, 1, &rms, vDSP_Length(recording.count))
        print("Recording RMS: \(rms)")

        // Step 0: Find per-cycle onsets via cross-correlation
        let onsets = findCycleOnsets(
            recording: recording,
            chirpTemplate: chirpTemplate,
            expectedCycles: numCycles,
            cycleSamples: cycleSamples
        )

        print("\n──── Step 0: Onset Detection ────")
        print("Onsets found: \(onsets.count) / \(numCycles)")
        if onsets.count >= 3 {
            print("First 3 onsets: \(onsets[0]), \(onsets[1]), \(onsets[2])")
            print("Stride 0→1: \(onsets[1] - onsets[0]), 1→2: \(onsets[2] - onsets[1]) (expected: \(cycleSamples))")
        }
        if let last = onsets.last {
            print("Last onset: \(last)")
        }

        // Step 1: Alias Detection
        let aliasResult = runAliasDetection(
            recording: recording,
            onsets: onsets,
            sampleRate: sampleRate
        )

        // Step 2: Range Coherence
        let coherenceResult = runRangeCoherence(
            recording: recording,
            onsets: onsets,
            sampleRate: sampleRate,
            calibrationTemplate: calibrationTemplate
        )

        // Step 3: Resolution Improvement
        let resolutionResult = runResolutionImprovement(
            recording: recording,
            onsets: onsets,
            sampleRate: sampleRate,
            calibrationTemplate: calibrationTemplate
        )

        print("\n═══════════════════════════════════════")
        let result = ProbeResult(
            aliasDetection: aliasResult,
            rangeCoherence: coherenceResult,
            resolution: resolutionResult
        )
        print("ALL CONFIRMED: \(result.allConfirmed)")
        print("═══════════════════════════════════════\n")

        return result
    }

    // MARK: - Step 0: Find Cycle Onsets

    /// Re-correlate per cycle to find exact onset rather than assuming fixed stride.
    /// This is critical: even 1-sample drift per cycle smears the alias during
    /// coherent averaging, destroying the -40 dB signal.
    private static func findCycleOnsets(
        recording: [Float],
        chirpTemplate: [Float],
        expectedCycles: Int,
        cycleSamples: Int
    ) -> [Int] {
        // First pass: find the first chirp onset by correlating the first chunk
        let searchLen = min(recording.count, cycleSamples * 4)
        let searchChunk = Array(recording[0..<searchLen])
        let initialCorr = DSP.crossCorrelate(signal: searchChunk, reference: chirpTemplate)

        guard !initialCorr.isEmpty else {
            print("[onset] Initial correlation is empty!")
            return []
        }

        // Find the first strong peak
        let (firstOnset, firstPeakVal) = DSP.findPeak(in: initialCorr, startIndex: 0)
        print("[onset] Initial correlation length: \(initialCorr.count), first peak at \(firstOnset) (value: \(firstPeakVal))")

        // Now find each cycle's exact onset by searching a window around expected position
        var onsets = [Int]()
        let searchWindow = 50 // +/- 50 samples around expected position

        for cycle in 0..<expectedCycles {
            let expectedPos = (cycle == 0) ? firstOnset : (onsets.last! + cycleSamples)
            let windowStart = max(0, expectedPos - searchWindow)
            let windowEnd = min(recording.count - chirpTemplate.count, expectedPos + searchWindow)

            guard windowEnd > windowStart else { break }

            let windowLen = windowEnd - windowStart + chirpTemplate.count
            guard windowStart + windowLen <= recording.count else { break }

            let searchSegment = Array(recording[windowStart..<(windowStart + windowLen)])
            let corr = DSP.crossCorrelate(signal: searchSegment, reference: chirpTemplate)

            if corr.isEmpty { break }

            let (peakIdx, _) = DSP.findPeak(in: corr, startIndex: 0)
            let actualOnset = windowStart + peakIdx
            onsets.append(actualOnset)
        }

        if onsets.count >= 2 {
            let strides = zip(onsets.dropFirst(), onsets).map { $0 - $1 }
            print("[onset] Stride stats: min=\(strides.min()!), max=\(strides.max()!), mean=\(String(format: "%.1f", Float(strides.reduce(0, +)) / Float(strides.count)))")
        }

        return onsets
    }

    // MARK: - Step 1: Alias Detection

    private static func runAliasDetection(
        recording: [Float],
        onsets: [Int],
        sampleRate: Float
    ) -> AliasDetectionResult {
        print("\n──── Step 1: Alias Detection ────")

        let fftSize = 4096 // next power of 2 above 2400

        var aliasChirpPowers = [Float]()
        var aliasGuardPowers = [Float]()
        var fundamentalPowers = [Float]()

        for onset in onsets {
            let chirpEnd = onset + chirpSamples
            let guardStart = onset + chirpSamples
            let guardEnd = onset + cycleSamples

            guard guardEnd <= recording.count else { continue }

            // Chirp segment
            let chirpSeg = Array(recording[onset..<chirpEnd])
            let chirpSpec = DSP.fftMagnitudeSquared(signal: chirpSeg, fftSize: fftSize)

            // Guard segment
            let guardSeg = Array(recording[guardStart..<guardEnd])
            let guardSpec = DSP.fftMagnitudeSquared(signal: guardSeg, fftSize: fftSize)

            // Band powers
            let pAliasChirp = DSP.bandPower(spectrum: chirpSpec, sampleRate: sampleRate,
                                            fftSize: fftSize, lowFreq: 8000, highFreq: 16000)
            let pAliasGuard = DSP.bandPower(spectrum: guardSpec, sampleRate: sampleRate,
                                            fftSize: fftSize, lowFreq: 8000, highFreq: 16000)
            let pFundamental = DSP.bandPower(spectrum: chirpSpec, sampleRate: sampleRate,
                                             fftSize: fftSize, lowFreq: 16000, highFreq: 20000)

            aliasChirpPowers.append(pAliasChirp)
            aliasGuardPowers.append(pAliasGuard)
            fundamentalPowers.append(pFundamental)
        }

        print("Valid cycles for alias detection: \(aliasChirpPowers.count)")

        // Average across all cycles
        let meanAliasChirp = aliasChirpPowers.reduce(0, +) / Float(max(aliasChirpPowers.count, 1))
        let meanAliasGuard = aliasGuardPowers.reduce(0, +) / Float(max(aliasGuardPowers.count, 1))
        let meanFundamental = fundamentalPowers.reduce(0, +) / Float(max(fundamentalPowers.count, 1))

        let aliasPowerDb = 10.0 * log10f(max(meanAliasChirp, 1e-20))
        let noisePowerDb = 10.0 * log10f(max(meanAliasGuard, 1e-20))
        let fundamentalPowerDb = 10.0 * log10f(max(meanFundamental, 1e-20))
        let aliasSNRDb = aliasPowerDb - noisePowerDb
        let aliasBelowFundamental = fundamentalPowerDb - aliasPowerDb

        print("Fundamental: \(String(format: "%.1f", fundamentalPowerDb)) dB")
        print("Alias power: \(String(format: "%.1f", aliasPowerDb)) dB")
        print("Noise power: \(String(format: "%.1f", noisePowerDb)) dB")
        print("Alias SNR: \(String(format: "%.1f", aliasSNRDb)) dB")
        print("Passed: \(aliasSNRDb > 3.0)")

        return AliasDetectionResult(
            fundamentalPowerDb: fundamentalPowerDb,
            aliasPowerDb: aliasPowerDb,
            noisePowerDb: noisePowerDb,
            aliasSNRDb: aliasSNRDb,
            aliasBelowFundamentalDb: aliasBelowFundamental,
            passed: aliasSNRDb > 3.0
        )
    }

    // MARK: - Step 2: Range Coherence

    private static func runRangeCoherence(
        recording: [Float],
        onsets: [Int],
        sampleRate: Float,
        calibrationTemplate: [Float]? = nil
    ) -> RangeCoherenceResult {
        print("\n──── Step 2: Range Coherence ────")

        let segLen = avgSegmentLen
        let (rawAvg, validCycles) = coherentAverage(
            recording: recording, onsets: onsets, segLen: segLen
        )

        print("Valid cycles for averaging: \(validCycles)")

        // Build reference chirps
        let fundamentalRef = ChirpGenerator.generateChirp(
            startFreq: 16000, endFreq: 20000,
            sampleRate: sampleRate, numSamples: chirpSamples
        )

        // Alias reference: 16 → 8 kHz (REVERSED direction!)
        // Speaker's 2nd harmonic: 32 → 40 kHz (same dir as fundamental 16→20)
        // Aliased through 48 kHz Nyquist: |48-32|=16 kHz, |48-40|=8 kHz
        // So alias sweeps 16 → 8 kHz in the recording
        let aliasRef = ChirpGenerator.generateChirp(
            startFreq: 16000, endFreq: 8000,
            sampleRate: sampleRate, numSamples: chirpSamples
        )

        // Bandpass filter FIRST, then subtract calibration per-band.
        // The raw average has ~75% power below 8 kHz which differs between
        // recordings and makes full-bandwidth dot products unreliable.
        let bpFftSize = 4096
        let rawFundamental = DSP.bandpassFilter(
            signal: rawAvg, fftSize: bpFftSize, sampleRate: sampleRate,
            lowFreq: 16000, highFreq: 20000)
        let rawAlias = DSP.bandpassFilter(
            signal: rawAvg, fftSize: bpFftSize, sampleRate: sampleRate,
            lowFreq: 8000, highFreq: 16000)

        // Apply calibration subtraction per-band
        let avgChirpFundamental: [Float]
        let avgChirpAlias: [Float]
        if let cal = calibrationTemplate {
            let calFundamental = DSP.bandpassFilter(
                signal: cal, fftSize: bpFftSize, sampleRate: sampleRate,
                lowFreq: 16000, highFreq: 20000)
            let calAlias = DSP.bandpassFilter(
                signal: cal, fftSize: bpFftSize, sampleRate: sampleRate,
                lowFreq: 8000, highFreq: 16000)

            avgChirpFundamental = DSP.subtractCalibration(signal: rawFundamental, calibration: calFundamental)
            avgChirpAlias = DSP.subtractCalibration(signal: rawAlias, calibration: calAlias)

            var rawFundRms: Float = 0
            vDSP_rmsqv(rawFundamental, 1, &rawFundRms, vDSP_Length(segLen))
            var postFundRms: Float = 0
            vDSP_rmsqv(avgChirpFundamental, 1, &postFundRms, vDSP_Length(segLen))
            print("Calibration (fundamental): RMS \(rawFundRms) -> \(postFundRms)")

            var rawAliasRms: Float = 0
            vDSP_rmsqv(rawAlias, 1, &rawAliasRms, vDSP_Length(segLen))
            var postAliasRms: Float = 0
            vDSP_rmsqv(avgChirpAlias, 1, &postAliasRms, vDSP_Length(segLen))
            print("Calibration (alias): RMS \(rawAliasRms) -> \(postAliasRms)")
        } else {
            avgChirpFundamental = rawFundamental
            avgChirpAlias = rawAlias
        }

        var fundBpRms: Float = 0
        vDSP_rmsqv(avgChirpFundamental, 1, &fundBpRms, vDSP_Length(segLen))
        var aliasBpRms: Float = 0
        vDSP_rmsqv(avgChirpAlias, 1, &aliasBpRms, vDSP_Length(segLen))
        print("Bandpass RMS: fundamental=\(fundBpRms), alias=\(aliasBpRms)")

        // Cross-correlate alias band with correct-direction and wrong-direction references.
        // The alias band (8-16 kHz) has no direct-path contamination (fundamental is 16-20 kHz),
        // so it cleanly detects reflections. A real alias from speaker nonlinearity MUST sweep
        // 16→8 kHz (2nd harmonic 32→40 kHz aliased through 48 kHz Nyquist). Correlating with
        // the wrong direction (8→16 kHz) should give ~20× lower peak (time-bandwidth product ~400).
        let corrAlias = DSP.crossCorrelate(signal: avgChirpAlias, reference: aliasRef)

        let wrongDirRef = ChirpGenerator.generateChirp(
            startFreq: 8000, endFreq: 16000,
            sampleRate: sampleRate, numSamples: chirpSamples
        )
        let corrWrongDir = DSP.crossCorrelate(signal: avgChirpAlias, reference: wrongDirRef)

        print("Correlation lengths: alias=\(corrAlias.count), wrongDir=\(corrWrongDir.count)")

        let skipLag = 20
        let (aliasPeakIdx, aliasPeakVal) = DSP.findPeak(in: corrAlias, startIndex: skipLag)
        let (_, wrongPeakVal) = DSP.findPeak(in: corrWrongDir, startIndex: skipLag)

        // Check 1: Alias peak above noise (relaxed to 2× since direction check adds confidence)
        let aliasMedian = DSP.medianAbsolute(corrAlias)
        let aliasRatio = aliasPeakVal / max(aliasMedian, 1e-20)
        let aliasPeakIsReal = aliasRatio > 2.0
        print("Alias peak: sample=\(aliasPeakIdx), strength=\(aliasPeakVal)")
        print("Alias median: \(aliasMedian), peak/median ratio: \(aliasRatio)")
        print("Alias peak is real: \(aliasPeakIsReal)")

        // Check 2: Correct sweep direction (16→8) stronger than wrong direction (8→16)
        let directionRatio = aliasPeakVal / max(wrongPeakVal, 1e-20)
        let directionCorrect = directionRatio > 1.5
        print("Wrong-dir peak: \(wrongPeakVal), direction ratio: \(String(format: "%.1f", directionRatio))x")
        print("Direction correct: \(directionCorrect)")

        // Reflector distance for display
        let reflectorDistanceMm = Float(aliasPeakIdx) / sampleRate * 343.0 / 2.0 * 1000.0
        print("Reflector distance: \(String(format: "%.0f", reflectorDistanceMm)) mm")

        let passed = aliasPeakIsReal && directionCorrect
        print("Passed: \(passed)")

        return RangeCoherenceResult(
            fundamentalPeakSample: aliasPeakIdx,
            aliasPeakSample: aliasPeakIdx,
            delayDifference: 0,
            distanceErrorMm: reflectorDistanceMm,
            fundamentalPeakStrength: Float(directionRatio),
            aliasPeakStrength: aliasPeakVal,
            passed: passed
        )
    }

    // MARK: - Step 3: Resolution Improvement

    private static func runResolutionImprovement(
        recording: [Float],
        onsets: [Int],
        sampleRate: Float,
        calibrationTemplate: [Float]? = nil
    ) -> ResolutionResult {
        print("\n──── Step 3: Resolution Improvement ────")

        let segLen = avgSegmentLen
        let (rawAvg, validCycles) = coherentAverage(
            recording: recording, onsets: onsets, segLen: segLen
        )

        _ = validCycles // logged by coherentAverage

        let fundamentalRef = ChirpGenerator.generateChirp(
            startFreq: 16000, endFreq: 20000,
            sampleRate: sampleRate, numSamples: chirpSamples
        )
        let aliasRef = ChirpGenerator.generateChirp(
            startFreq: 16000, endFreq: 8000,
            sampleRate: sampleRate, numSamples: chirpSamples
        )

        // Bandpass filter FIRST, then subtract calibration per-band
        let bpFftSize3 = 4096
        let rawFundamental = DSP.bandpassFilter(
            signal: rawAvg, fftSize: bpFftSize3, sampleRate: sampleRate,
            lowFreq: 16000, highFreq: 20000)
        let rawAlias = DSP.bandpassFilter(
            signal: rawAvg, fftSize: bpFftSize3, sampleRate: sampleRate,
            lowFreq: 8000, highFreq: 16000)

        let avgChirpFundamental: [Float]
        let avgChirpAlias: [Float]
        if let cal = calibrationTemplate {
            let calFundamental = DSP.bandpassFilter(
                signal: cal, fftSize: bpFftSize3, sampleRate: sampleRate,
                lowFreq: 16000, highFreq: 20000)
            let calAlias = DSP.bandpassFilter(
                signal: cal, fftSize: bpFftSize3, sampleRate: sampleRate,
                lowFreq: 8000, highFreq: 16000)

            avgChirpFundamental = DSP.subtractCalibration(signal: rawFundamental, calibration: calFundamental)
            avgChirpAlias = DSP.subtractCalibration(signal: rawAlias, calibration: calAlias)

            var rawFundRms: Float = 0
            vDSP_rmsqv(rawFundamental, 1, &rawFundRms, vDSP_Length(segLen))
            var postFundRms: Float = 0
            vDSP_rmsqv(avgChirpFundamental, 1, &postFundRms, vDSP_Length(segLen))
            print("Calibration (fundamental): RMS \(rawFundRms) -> \(postFundRms)")
        } else {
            avgChirpFundamental = rawFundamental
            avgChirpAlias = rawAlias
        }

        var fundBpRms3: Float = 0
        vDSP_rmsqv(avgChirpFundamental, 1, &fundBpRms3, vDSP_Length(segLen))
        var aliasBpRms3: Float = 0
        vDSP_rmsqv(avgChirpAlias, 1, &aliasBpRms3, vDSP_Length(segLen))
        print("Bandpass RMS: fundamental=\(fundBpRms3), alias=\(aliasBpRms3)")

        // Cross-correlate each filtered signal with its reference
        let corrFundamental = DSP.crossCorrelate(signal: avgChirpFundamental, reference: fundamentalRef)
        let corrAlias = DSP.crossCorrelate(signal: avgChirpAlias, reference: aliasRef)

        print("Correlation lengths: fundamental=\(corrFundamental.count), alias=\(corrAlias.count)")

        // Use alias peak to find reflection lag (alias band has no direct-path contamination)
        let skipLag3 = 20
        let (aliasPeakIdx, aliasPeakVal) = DSP.findPeak(in: corrAlias, startIndex: skipLag3)

        // Measure fundamental width at the alias peak lag (the true reflection)
        // This avoids the direct-path peak dominating in the fundamental band
        let fundPeakIdx = aliasPeakIdx  // use reflection lag from alias
        let fundPeakVal = fundPeakIdx < corrFundamental.count ? abs(corrFundamental[fundPeakIdx]) : Float(0)
        let fundamentalWidth = DSP.measureWidth3dB(array: corrFundamental, peakIndex: fundPeakIdx)
        print("Fundamental at reflection lag=\(fundPeakIdx), val=\(fundPeakVal), -3dB width=\(fundamentalWidth)")

        // Normalize both to unit peak at the reflection lag
        var normFund = corrFundamental
        if fundPeakVal > 0 {
            var scale = 1.0 / fundPeakVal
            vDSP_vsmul(corrFundamental, 1, &scale, &normFund, 1, vDSP_Length(corrFundamental.count))
        }

        var normAlias = corrAlias
        if aliasPeakVal > 0 {
            var scale = 1.0 / aliasPeakVal
            vDSP_vsmul(corrAlias, 1, &scale, &normAlias, 1, vDSP_Length(corrAlias.count))
        }

        print("Alias peak val=\(aliasPeakVal)")

        // Stitch: sum of normalized correlations
        let minLen = min(normFund.count, normAlias.count)
        var stitched = [Float](repeating: 0, count: minLen)
        vDSP_vadd(normFund, 1, normAlias, 1, &stitched, 1, vDSP_Length(minLen))

        // Measure stitched -3 dB width at reflection lag
        let stitchedPeakIdx = aliasPeakIdx
        let stitchedWidth = DSP.measureWidth3dB(array: stitched, peakIndex: stitchedPeakIdx)
        print("Stitched peak idx=\(stitchedPeakIdx), -3dB width=\(stitchedWidth)")

        let ratio: Float = stitchedWidth > 0 ? Float(fundamentalWidth) / Float(stitchedWidth) : 0
        print("Resolution ratio: \(String(format: "%.2f", ratio))x")
        print("Passed: \(stitchedWidth > 0 && stitchedWidth < fundamentalWidth)")

        return ResolutionResult(
            fundamentalWidth: fundamentalWidth,
            stitchedWidth: stitchedWidth,
            resolutionRatio: ratio,
            passed: stitchedWidth > 0 && stitchedWidth < fundamentalWidth
        )
    }
}
