//
//  LiveMicController.swift
//  Child Gun Safety
//
//  Captures microphone audio and streams 16-bit PCM mono @ 24 kHz
//  into GeminiFlashLiveClient. The Gemini Live API performs its own
//  voice activity detection (VAD), so the client streams continuously.
//

import Foundation
import AVFoundation
import Speech

@MainActor
final class LiveMicController {

    static let shared = LiveMicController()

    // MARK: - Public callbacks

    /// RMS level of the mic input, useful for "speaking" indicators / UI.
    var onLevelUpdate: ((Float) -> Void)?

    /// Called if anything goes wrong with audio capture.
    var onError: ((Error) -> Void)?

    /// Optional callbacks for UI state; not automatically triggered now that
    /// the Live API performs server-side VAD.
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?
    
    // MARK: - Private state

    private let engine = AVAudioEngine()
    private var isRunning = false

    /// Target sample rate + format for Gemini Live audio input.
    private let targetSampleRate: Double = 24_000
    private let rmsLogFloor: Float = -60.0

    private var currentClient: GeminiFlashLiveClient?

    // MARK: - Speech recognition debug

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var lastPrintedTranscript: String = ""

    // MARK: - Public API

    /// Starts capturing mic audio and streaming it into GeminiFlashLiveClient.
    func startStreaming(to client: GeminiFlashLiveClient = .shared) {
        guard !isRunning else { return }

        currentClient = client

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

        currentClient = nil

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()
        stopSpeechRecognition()

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

        startSpeechRecognition()
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

        // Compute RMS for UI level meters.
        let rms = bufferRMS(buffer: buffer)
        onLevelUpdate?(rms)

        // Feed the buffer into the debug speech recognizer to log words sent upstream.
        recognitionRequest?.append(buffer)

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

    // MARK: - Utility


    /// Compute RMS in dBFS for a buffer (for UI level meters).
    private func bufferRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let floatData = buffer.floatChannelData else { return rmsLogFloor }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        if frameCount == 0 { return rmsLogFloor }

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

        guard totalSamples > 0 else { return rmsLogFloor }
        let meanSquare = sumSquares / Float(totalSamples)
        let rms = sqrt(meanSquare)
        let db = 20.0 * log10(rms + 1e-7)  // avoid log(0)
        return max(db, rmsLogFloor)
    }

    // MARK: - Speech recognition logging

    private func startSpeechRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest?.shouldReportPartialResults = true
        lastPrintedTranscript = ""

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("⚠️ [LiveMic] Speech recognizer unavailable for debug logging")
            return
        }

        guard let recognitionRequest else { return }

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty {
                    if self.lastPrintedTranscript.isEmpty {
                        self.onSpeechStart?()
                    }

                    if text != self.lastPrintedTranscript {
                        self.lastPrintedTranscript = text
                        print("🗣️ [LiveMic][debug ASR] \(text)")
                    }
                }
            }

            if let error {
                print("⚠️ [LiveMic] Speech recognition error: \(error.localizedDescription)")
                self.recognitionTask?.cancel()
                self.recognitionTask = nil
            }
        }
    }

    private func stopSpeechRecognition() {
        if !lastPrintedTranscript.isEmpty {
            onSpeechEnd?()
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        lastPrintedTranscript = ""
    }

}
