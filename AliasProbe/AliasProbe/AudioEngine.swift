import Foundation
import AVFoundation
import Accelerate

actor AudioEngine {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var recordedSamples: [Float] = []
    private var isCapturing = false

    /// Actual sample rate after session configuration.
    private(set) var actualSampleRate: Double = 48000.0

    /// Play the chirp buffer through the speaker and simultaneously record from the mic.
    /// Returns the raw recorded Float32 samples.
    func playAndRecord(
        playbackBuffer: [Float],
        expectedDuration: TimeInterval,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [Float] {
        // Configure audio session
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, options: [.defaultToSpeaker])
        try session.setPreferredSampleRate(48000)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)

        actualSampleRate = session.sampleRate

        // Create engine and player
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        self.engine = engine
        self.playerNode = playerNode

        // Get the hardware format for the input node
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Create playback buffer in the output format
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let sr = outputFormat.sampleRate

        // Connect player → main mixer with output format
        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)

        // Prepare the PCM buffer for playback
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(playbackBuffer.count)
        ) else {
            throw AudioEngineError.bufferCreationFailed
        }
        pcmBuffer.frameLength = AVAudioFrameCount(playbackBuffer.count)

        if let channelData = pcmBuffer.floatChannelData {
            // If stereo, write same data to both channels
            let channelCount = Int(outputFormat.channelCount)
            for ch in 0..<channelCount {
                memcpy(channelData[ch], playbackBuffer, playbackBuffer.count * MemoryLayout<Float>.size)
            }
        }

        // Set up recording accumulator
        recordedSamples = []
        recordedSamples.reserveCapacity(Int(sr * (expectedDuration + 2.0)))
        isCapturing = true

        // Use input node's native format for the tap — requesting a different
        // format (e.g. mono when hardware is stereo) silently produces zeros.
        print("[audio] Input format: \(inputFormat)")
        print("[audio] Output format: \(outputFormat)")
        print("[audio] Session sample rate: \(session.sampleRate)")

        let capturedSamples = UnsafeMutablePointer<[Float]>.allocate(capacity: 1)
        capturedSamples.initialize(to: [])

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: data, count: count))
            capturedSamples.pointee.append(contentsOf: samples)
        }

        // Start engine
        try engine.start()

        // Small delay to ensure recording is active before playback
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // Schedule and play
        playerNode.scheduleBuffer(pcmBuffer, at: nil, options: []) {
            // Playback complete
        }
        playerNode.play()

        // Monitor progress
        let startTime = Date()
        let totalDuration = expectedDuration

        while Date().timeIntervalSince(startTime) < totalDuration + 1.0 {
            let elapsed = Date().timeIntervalSince(startTime)
            let progress = min(elapsed / totalDuration, 1.0)
            onProgress(progress)
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms updates
        }

        // Wait a bit after playback ends to capture tail
        try await Task.sleep(nanoseconds: 500_000_000)

        // Stop everything
        inputNode.removeTap(onBus: 0)
        playerNode.stop()
        engine.stop()

        let result = capturedSamples.pointee
        capturedSamples.deinitialize(count: 1)
        capturedSamples.deallocate()

        try session.setActive(false, options: .notifyOthersOnDeactivation)

        self.engine = nil
        self.playerNode = nil

        return result
    }
}

enum AudioEngineError: Error, LocalizedError {
    case bufferCreationFailed
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .bufferCreationFailed: return "Failed to create audio buffer"
        case .recordingFailed: return "Recording failed"
        }
    }
}
