import SwiftUI

struct ContentView: View {
    @State private var probeState: ProbeState = .idle
    @State private var progress: Double = 0.0
    @State private var calibrationTemplate: [Float]? = nil

    private let audioEngine = AudioEngine()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerSection
                    controlSection
                    resultsSection
                }
                .padding()
            }
            .navigationTitle("AliasProbe")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        VStack(spacing: 4) {
            Text("Acoustic FMCW Alias Detection")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Proves aliased 2nd-harmonic content extends bandwidth from 4 kHz → 12 kHz on stock iPhone hardware.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var calibrationBadge: some View {
        if calibrationTemplate != nil {
            Label("Calibrated", systemImage: "checkmark.seal.fill")
                .font(.caption.bold())
                .foregroundColor(.green)
        } else {
            Label("Not calibrated", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private var controlSection: some View {
        switch probeState {
        case .idle:
            VStack(spacing: 10) {
                calibrationBadge
                HStack(spacing: 12) {
                    Button(action: runCalibration) {
                        Label("Calibrate", systemImage: "scope")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button(action: runProbe) {
                        Label("Run Probe", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(calibrationTemplate == nil)
                }
                if calibrationTemplate == nil {
                    Text("Calibrate first with no reflector nearby")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

        case .calibrating:
            VStack(spacing: 8) {
                HStack {
                    ProgressView()
                    Text("Calibrating...")
                        .font(.headline)
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Keep reflector away from device")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
            )

        case .recording:
            VStack(spacing: 8) {
                HStack {
                    ProgressView()
                    Text("Recording...")
                        .font(.headline)
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
            )

        case .analyzing:
            VStack(spacing: 8) {
                ProgressView()
                Text("Analyzing...")
                    .font(.headline)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
            )

        case .done:
            VStack(spacing: 10) {
                calibrationBadge
                HStack(spacing: 12) {
                    Button(action: runCalibration) {
                        Label("Recalibrate", systemImage: "scope")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button(action: runProbe) {
                        Label("Run Again", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
            }

        case .error(let msg):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                calibrationBadge
                HStack(spacing: 12) {
                    Button("Recalibrate", action: runCalibration)
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    Button("Try Again", action: runProbe)
                        .buttonStyle(.bordered)
                }
            }
            .padding()
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        if case .done(let result) = probeState {
            // Card 1: Alias Detection
            ResultCardView(
                title: "Alias Detection",
                passed: result.aliasDetection.passed,
                verdict: result.aliasDetection.passed ? "DETECTED" : "NOT DETECTED",
                details: [
                    ("Fundamental power", String(format: "%.1f dB", result.aliasDetection.fundamentalPowerDb)),
                    ("Alias band power (chirp on)", String(format: "%.1f dB", result.aliasDetection.aliasPowerDb)),
                    ("Alias band noise (chirp off)", String(format: "%.1f dB", result.aliasDetection.noisePowerDb)),
                    ("Alias SNR", String(format: "%.1f dB", result.aliasDetection.aliasSNRDb)),
                    ("Alias below fundamental", String(format: "%.1f dB", result.aliasDetection.aliasBelowFundamentalDb)),
                ]
            )

            // Card 2: Range Coherence
            ResultCardView(
                title: "Range Coherence",
                passed: result.rangeCoherence.passed,
                verdict: result.rangeCoherence.passed ? "COHERENT" : "NOT COHERENT",
                details: [
                    ("Reflection at sample", "\(result.rangeCoherence.aliasPeakSample)"),
                    ("Reflector distance", String(format: "%.0f mm", result.rangeCoherence.distanceErrorMm)),
                    ("Alias peak strength", String(format: "%.4f", result.rangeCoherence.aliasPeakStrength)),
                    ("Direction ratio", String(format: "%.1fx", result.rangeCoherence.fundamentalPeakStrength)),
                ]
            )

            // Card 3: Resolution Improvement
            ResultCardView(
                title: "Resolution Improvement",
                passed: result.resolution.passed,
                verdict: result.resolution.passed ? "IMPROVED" : "NOT IMPROVED",
                details: [
                    ("Fundamental peak width", "\(result.resolution.fundamentalWidth) samples"),
                    ("Stitched peak width", "\(result.resolution.stitchedWidth) samples"),
                    ("Resolution improvement", String(format: "%.2fx", result.resolution.resolutionRatio)),
                ]
            )

            // Final banner
            if result.allConfirmed {
                Text("CONFIRMED: Aliased harmonics extend bandwidth from 4 kHz to ~12 kHz. Range resolution improves from 4.3 cm to ~1.4 cm on stock iPhone hardware.")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.green)
                    )
            } else {
                VStack(spacing: 4) {
                    Text("NOT ALL CONFIRMED")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    let failures = [
                        result.aliasDetection.passed ? nil : "Alias Detection",
                        result.rangeCoherence.passed ? nil : "Range Coherence",
                        result.resolution.passed ? nil : "Resolution Improvement",
                    ].compactMap { $0 }
                    Text("Failed: \(failures.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.9))
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.red)
                )
            }
        }
    }

    // MARK: - Audio Helpers

    private func generateChirpAndBuffer() -> (chirp: [Float], playbackBuffer: [Float], sampleRate: Float) {
        let sampleRate: Float = 48000
        let chirp = ChirpGenerator.generateChirp(
            startFreq: 16000, endFreq: 20000,
            sampleRate: sampleRate, numSamples: 2400
        )
        let playbackBuffer = ChirpGenerator.generatePlaybackBuffer(
            chirp: chirp,
            guardSamples: 1200,
            cycles: 200,
            leadingSilenceSamples: 24000 // 0.5s leading silence
        )
        return (chirp, playbackBuffer, sampleRate)
    }

    // MARK: - Calibration

    private func runCalibration() {
        Task {
            do {
                let (chirp, playbackBuffer, sampleRate) = generateChirpAndBuffer()
                let expectedDuration = Double(playbackBuffer.count) / Double(sampleRate)

                probeState = .calibrating(progress: 0)
                let recording = try await audioEngine.playAndRecord(
                    playbackBuffer: playbackBuffer,
                    expectedDuration: expectedDuration
                ) { prog in
                    Task { @MainActor in
                        progress = prog
                        probeState = .calibrating(progress: prog)
                    }
                }

                await MainActor.run {
                    probeState = .analyzing
                }

                let actualSR = await audioEngine.actualSampleRate
                let template = await Task.detached {
                    AnalysisPipeline.calibrate(
                        recording: recording,
                        chirpTemplate: chirp,
                        sampleRate: Float(actualSR)
                    )
                }.value

                await MainActor.run {
                    calibrationTemplate = template
                    probeState = .idle
                }

            } catch {
                await MainActor.run {
                    probeState = .error(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Run Probe

    private func runProbe() {
        let calTemplate = calibrationTemplate
        Task {
            do {
                let (chirp, playbackBuffer, sampleRate) = generateChirpAndBuffer()
                let expectedDuration = Double(playbackBuffer.count) / Double(sampleRate)

                probeState = .recording(progress: 0)
                let recording = try await audioEngine.playAndRecord(
                    playbackBuffer: playbackBuffer,
                    expectedDuration: expectedDuration
                ) { prog in
                    Task { @MainActor in
                        progress = prog
                        probeState = .recording(progress: prog)
                    }
                }

                await MainActor.run {
                    probeState = .analyzing
                }

                let actualSR = await audioEngine.actualSampleRate
                let result = await Task.detached {
                    AnalysisPipeline.analyze(
                        recording: recording,
                        chirpTemplate: chirp,
                        sampleRate: Float(actualSR),
                        calibrationTemplate: calTemplate
                    )
                }.value

                await MainActor.run {
                    probeState = .done(result)
                }

            } catch {
                await MainActor.run {
                    probeState = .error(error.localizedDescription)
                }
            }
        }
    }
}
