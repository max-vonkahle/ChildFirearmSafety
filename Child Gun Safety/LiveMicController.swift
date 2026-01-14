//
//  LiveMicController.swift
//  Child Gun Safety
//
//  Captures microphone audio and resamples to 16-bit PCM mono @ 24 kHz
//  for streaming into GeminiFlashLiveClient.
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

    /// Optional callbacks for UI state.
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?

    // MARK: - Private state

    private let engine = AVAudioEngine()
    private var isRunning = false

    /// Target sample rate for Gemini Live audio input (24 kHz for native audio API).
    private let targetSampleRate: Double = 24_000
    private let rmsLogFloor: Float = -60.0

    private var currentClient: GeminiFlashLiveClient?
    
    // Resampling converter
    private var converter: AVAudioConverter?

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
        converter = nil
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

        // Ask for 24 kHz if possible
        try session.setPreferredSampleRate(targetSampleRate)

        try session.setActive(true, options: [])
    }

    private func startEngineAndTap(to client: GeminiFlashLiveClient) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // Create target format: 16-bit PCM mono @ 24 kHz
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(domain: "LiveMic", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format"])
        }

        // Create converter from input format to target format
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "LiveMic", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
        }
        self.converter = converter

        #if DEBUG
        // print("[LiveMic] Input format:", inputFormat)
        // print("[LiveMic] Target format:", targetFormat)
        #endif

        input.removeTap(onBus: 0)

        input.installTap(
            onBus: 0,
            bufferSize: 4096,  // Larger buffer for resampling
            format: inputFormat
        ) { [weak self] buffer, _ in
            guard let self else { return }
            self.process(buffer: buffer, converter: converter, client: client)
        }

        engine.prepare()
        try engine.start()

        startSpeechRecognition()
    }

    // MARK: - Buffer processing

    /// Resample and convert the buffer to 16-bit mono @ 24k, then stream.
    private func process(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        client: GeminiFlashLiveClient
    ) {
        // Compute RMS for UI level meters (on original buffer)
        let rms = bufferRMS(buffer: buffer)
        onLevelUpdate?(rms)

        // Feed the buffer into the debug speech recognizer
        recognitionRequest?.append(buffer)

        // Calculate output buffer size based on sample rate conversion
        let inputFrameCount = buffer.frameLength
        let conversionRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(inputFrameCount) * conversionRatio)

        // Create output buffer for converted audio
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            // print("🟥 [LiveMic] Failed to create output buffer")
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error {
            // print("🟥 [LiveMic] Conversion error: \(error)")
            return
        }

        // Extract Int16 data from the output buffer
        guard let int16Data = outputBuffer.int16ChannelData else {
            // print("🟥 [LiveMic] No int16 channel data")
            return
        }

        let frameCount = Int(outputBuffer.frameLength)
        let channel = int16Data[0]
        
        // Convert Int16 array to Data
        var pcmData = Data(capacity: frameCount * MemoryLayout<Int16>.size)
        for i in 0..<frameCount {
            var sample = channel[i].littleEndian
            withUnsafeBytes(of: &sample) { bytes in
                pcmData.append(contentsOf: bytes)
            }
        }

        #if DEBUG
        // Occasional logging to verify we're sending data
        if Int.random(in: 0..<100) == 0 {
            // print("🎤 [LiveMic] Converted \(inputFrameCount) frames → \(frameCount) frames (\(pcmData.count) bytes)")
        }
        #endif

        // Stream the PCM chunk into Gemini Live
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
        let db = 20.0 * log10(rms + 1e-7)
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
            // print("⚠️ [LiveMic] Speech recognizer unavailable for debug logging")
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
