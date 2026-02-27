import Foundation

// MARK: - Experiment Results

struct AliasDetectionResult {
    let fundamentalPowerDb: Float
    let aliasPowerDb: Float
    let noisePowerDb: Float
    let aliasSNRDb: Float
    let aliasBelowFundamentalDb: Float
    let passed: Bool
}

struct RangeCoherenceResult {
    let fundamentalPeakSample: Int
    let aliasPeakSample: Int
    let delayDifference: Int
    let distanceErrorMm: Float
    let fundamentalPeakStrength: Float
    let aliasPeakStrength: Float
    let passed: Bool
}

struct ResolutionResult {
    let fundamentalWidth: Int
    let stitchedWidth: Int
    let resolutionRatio: Float
    let passed: Bool
}

struct ProbeResult {
    let aliasDetection: AliasDetectionResult
    let rangeCoherence: RangeCoherenceResult
    let resolution: ResolutionResult

    var allConfirmed: Bool {
        aliasDetection.passed && rangeCoherence.passed && resolution.passed
    }
}

// MARK: - App State

enum ProbeState {
    case idle
    case calibrating(progress: Double)
    case recording(progress: Double)
    case analyzing
    case done(ProbeResult)
    case error(String)
}
