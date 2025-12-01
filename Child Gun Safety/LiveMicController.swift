//
//  LiveMicController.swift
//  Child Gun Safety
//
//  Captures microphone audio and streams 16-bit PCM mono @ 24 kHz
//  into GeminiFlashLiveClient with automatic Voice Activity Detection.
//

import Foundation
import AVFoundation

@MainActor
final class LiveMicController {

    static let shared = LiveMicController()

    // MARK: - Public callbacks

    /// RMS level of the mic input, useful for "speaking" indicators / UI.
    var onLevelUpdate: ((Float) -> Void)?

    /// Called if anything goes wrong with audio capture.
    var onError: ((Error) -> Void)?
    
    /// Called when the user is detected to be speaking.
    var onSpeechStart: (() -> Void)?
    
    /// Called when speech ends (silence detected).
    var onSpeechEnd: (() -> Void)?

    // MARK: - Private state

    private let engine = AVAudioEngine()
    private var isRunning = false

    /// Target sample rate + format for Gemini Live audio input.
    private let targetSampleRate: Double = 24_000
    private let vadLogFloor: Float = -60.0

    private var currentClient: GeminiFlashLiveClient?
    
    // MARK: - VAD Configuration
    
    /// Threshold in dB below which we consider it silence.
    /// Adjust based on your environment: -40 to -50 for quiet rooms, -30 for noisier.
    private let silenceThreshold: Float = -45.0
    
    /// How many consecutive silent buffers before we consider speech ended.
    /// At ~21ms per buffer (1024 samples @ 48kHz), 50 buffers ≈ 1 second
    private let silenceBuffersRequired: Int = 50
    
    /// How many consecutive speech buffers before we consider speech started.
    /// 10 buffers ≈ 200ms to avoid false triggers
    private let speechBuffersRequired: Int = 10
    
    private var consecutiveSilentBuffers: Int = 0
    private var consecutiveSpeechBuffers: Int = 0
    private var isSpeaking: Bool = false
    private var hasDetectedAnySpeech: Bool = false

    // MARK: - Public API

    /// Starts capturing mic audio and streaming it into GeminiFlashLiveClient.
    /// Will automatically detect when the user stops speaking and end the turn.
    func startStreaming(to client: GeminiFlashLiveClient = .shared) {
        guard !isRunning else { return }

        currentClient = client
        consecutiveSilentBuffers = 0
        consecutiveSpeechBuffers = 0
        isSpeaking = false
        hasDetectedAnySpeech = false
        
        Task {
            do {
                try await configureAudioSession()
                try startEngineAndTap(to: client)
                isRunning = true
            } catch {
                onError?(error)
                stop()
            }
        }
    }

    /// Stops capturing mic audio.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        let client = currentClient
        currentClient = nil

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()

        // Deactivate audio session
        do {
            let session = AVAudioSession.sharedInstance()
            if !session.isOtherAudioPlaying {
                try session.setActive(false, options: [.notifyOthersOnDeactivation])
            }
        } catch {
            print("[LiveMic] AVAudioSession deactivate error:", error.localizedDescription)
        }

        print("🛑 [LiveMic] Stopped audio capture")
    }

    // MARK: - Audio session & engine

    private func configureAudioSession() async throws {
        let session = AVAudioSession.sharedInstance()

        // Request mic permission if needed.
        let permission = await session.recordPermission
        if permission == .undetermined {
            let granted = await withCheckedContinuation { cont in
                session.requestRecordPermission { ok in
                    cont.resume(returning: ok)
                }
            }
            if !granted {
                throw NSError(
                    domain: "LiveMic",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Microphone access denied"]
                )
            }
        } else if permission != .granted {
            throw NSError(
                domain: "LiveMic",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Microphone access not granted"]
            )
        }

        // Duplex mode: record + play Gemini's audio with echo cancellation.
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth]
        )

        // Ask for 24 kHz if possible so conversion is simple.
        try session.setPreferredSampleRate(targetSampleRate)

        try session.setActive(true, options: [])
    }

    private func startEngineAndTap(to client: GeminiFlashLiveClient) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        #if DEBUG
        print("[LiveMic] Input format:", inputFormat)
        #endif

        input.removeTap(onBus: 0)

        input.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: inputFormat
        ) { [weak self] buffer, _ in
            guard let self else { return }
            self.process(buffer: buffer, inputFormat: inputFormat, client: client)
        }

        engine.prepare()
        try engine.start()
    }

    // MARK: - Buffer processing

    /// Convert the incoming buffer into 16-bit mono @ 24k and stream.
    private func process(
        buffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        client: GeminiFlashLiveClient
    ) {
        guard let floatData = buffer.floatChannelData else {
            return
        }

        let channelCount = Int(inputFormat.channelCount)
        let frameCount = Int(buffer.frameLength)
        if frameCount == 0 { return }

        // Compute RMS for VAD and UI.
        let rms = bufferRMS(buffer: buffer)
        onLevelUpdate?(rms)

        // Voice Activity Detection
        performVAD(rmsDB: rms)

        // Downmix to mono and clamp to [-1, 1], then quantize to Int16.
        var pcmData = Data()
        pcmData.reserveCapacity(frameCount * MemoryLayout<Int16>.size)

        for frame in 0..<frameCount {
            var sample: Float = 0.0
            // Average all channels into one mono sample.
            for ch in 0..<channelCount {
                let channel = floatData[ch]
                sample += channel[frame]
            }
            sample /= Float(max(channelCount, 1))

            // Clamp to [-1, 1].
            let clamped = max(-1.0, min(1.0, sample))

            // Convert to 16-bit signed integer.
            let intSample = Int16(clamped * Float(Int16.max))
            var littleEndian = intSample.littleEndian

            withUnsafeBytes(of: &littleEndian) { bytes in
                pcmData.append(bytes.bindMemory(to: UInt8.self))
            }
        }

        // Stream the PCM chunk into Gemini Live.
        Task { @MainActor in
            await client.sendAudioChunk(pcmData)
        }
    }

    // MARK: - Voice Activity Detection

    private func performVAD(rmsDB: Float) {
        let isSilent = rmsDB < silenceThreshold

        if isSilent {
            consecutiveSilentBuffers += 1
            consecutiveSpeechBuffers = 0
            
            // If we were speaking and now have enough silence, end the turn
            if isSpeaking && consecutiveSilentBuffers >= silenceBuffersRequired {
                isSpeaking = false
                print("🔇 [VAD] Speech ended (silence detected)")
                onSpeechEnd?()
                
                // Automatically stop the mic after detecting speech end
                // Only if we had detected some speech first
                if hasDetectedAnySpeech {
                    Task { @MainActor in
                        self.stop()
                    }
                }
            }
        } else {
            consecutiveSpeechBuffers += 1
            consecutiveSilentBuffers = 0
            
            // If we weren't speaking and now have enough speech, start the turn
            if !isSpeaking && consecutiveSpeechBuffers >= speechBuffersRequired {
                isSpeaking = true
                hasDetectedAnySpeech = true
                print("🎙️ [VAD] Speech started")
                onSpeechStart?()
            }
        }
        
        #if DEBUG
        // Uncomment for debugging VAD:
        // if consecutiveSilentBuffers % 10 == 0 || consecutiveSpeechBuffers % 10 == 0 {
        //     print("[VAD] RMS: \(rmsDB) dB | Silent: \(consecutiveSilentBuffers) | Speech: \(consecutiveSpeechBuffers)")
        // }
        #endif
    }

    // MARK: - Utility

    /// Compute RMS in dBFS for a buffer (for VAD / level meters).
    private func bufferRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let floatData = buffer.floatChannelData else { return vadLogFloor }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        if frameCount == 0 { return vadLogFloor }

        var sumSquares: Float = 0.0
        var totalSamples = 0

        for ch in 0..<channelCount {
            let channel = floatData[ch]
            for i in 0..<frameCount {
                let s = channel[i]
                sumSquares += s * s
                totalSamples += 1
            }
        }

        guard totalSamples > 0 else { return vadLogFloor }
        let meanSquare = sumSquares / Float(totalSamples)
        let rms = sqrt(meanSquare)
        let db = 20.0 * log10(rms + 1e-7)  // avoid log(0)
        return max(db, vadLogFloor)
    }
}
