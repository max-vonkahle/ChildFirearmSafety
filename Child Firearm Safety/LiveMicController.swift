//
//  LiveMicController.swift
//  Child Firearm Safety
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

    /// Called when a long pause is detected and we're finalizing the user's turn
    var onTurnComplete: ((String) -> Void)?  // Passes the transcript

    // MARK: - Private state

    private let engine = AVAudioEngine()
    private var isRunning = false

    // Background queue for audio engine operations to prevent main thread blocking
    private let audioQueue = DispatchQueue(label: "com.childgunsafety.miccontrol", qos: .userInteractive)

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
    private var recognitionRestartTask: Task<Void, Never>?

    // Two-tier VAD system:
    // - Short pause for UI feedback (1.2s)
    // - Long pause to signal end-of-turn to Gemini (3.0s)
    private var shortPauseTimer: Task<Void, Never>?
    private var longPauseTimer: Task<Void, Never>?
    private let shortPauseThreshold: TimeInterval = 1.2  // UI feedback
    private let longPauseThreshold: TimeInterval = 3.0   // End turn and let Gemini respond

    // MARK: - Public API

    /// Starts capturing mic audio and streaming it into GeminiFlashLiveClient.
    /// - Parameter skipAudioSessionConfig: If true, skips audio session configuration (use when caller already configured it)
    func startStreaming(to client: GeminiFlashLiveClient = .shared, skipAudioSessionConfig: Bool = false) {
        guard !isRunning else { return }

        currentClient = client

        // Use Task.detached to ensure audio session configuration runs off main thread
        // AudioSession configuration can block for 500-1000ms
        Task.detached(priority: .userInitiated) { [weak self, client] in
            guard let self else { return }
            let startTime = CACurrentMediaTime()
            // print("🎙️ [LiveMic] Task.detached started on thread: \(Thread.isMainThread ? "MAIN ⚠️" : "background ✅")")
            do {
                if skipAudioSessionConfig {
                    // print("🎙️ [LiveMic] Skipping audio session config (already configured)")
                } else {
                    try await self.configureAudioSession()
                    // print("⏱️ [LiveMic] configureAudioSession took \(Int((CACurrentMediaTime() - startTime) * 1000))ms")
                }

                // Move engine start operations to background queue to avoid blocking main thread
                let engineStartTime = CACurrentMediaTime()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.audioQueue.async { [weak self] in
                        guard let self = self else {
                            continuation.resume(throwing: NSError(domain: "LiveMic", code: 99, userInfo: nil))
                            return
                        }
                        do {
                            try self.startEngineAndTap(to: client)
                            // print("⏱️ [LiveMic] startEngineAndTap took \(Int((CACurrentMediaTime() - engineStartTime) * 1000))ms")
                            Task { @MainActor in
                                self.isRunning = true
                            }
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.onError?(error)
                    self.stop()
                }
            }
        }
    }

    /// Stops capturing mic audio.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        currentClient = nil

        // Move engine stop operations to background queue to avoid blocking main thread
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            let input = self.engine.inputNode
            input.removeTap(onBus: 0)
            self.engine.stop()

            Task { @MainActor in
                self.converter = nil
                self.shortPauseTimer?.cancel()
                self.shortPauseTimer = nil
                self.longPauseTimer?.cancel()
                self.longPauseTimer = nil
                self.recognitionRestartTask?.cancel()
                self.recognitionRestartTask = nil
                self.stopSpeechRecognition()
            }

            // NOTE: Don't deactivate audio session here - it stops the playback engine!
            // The session should stay active for the model's audio response.

            // print("🛑 [LiveMic] Stopped audio capture")
        }
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
        // .voiceChat mode provides built-in echo cancellation
        // .duckOthers reduces background audio interference
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .duckOthers]
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

        // Stream the PCM chunk into Gemini Live (always send, let server-side VAD handle turn detection)
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
                        // print("🗣️ [LiveMic][debug ASR] \(text)")

                        // Cancel any existing pause timers and start new ones
                        self.shortPauseTimer?.cancel()
                        self.longPauseTimer?.cancel()

                        // Short pause timer: UI feedback only
                        self.shortPauseTimer = Task { @MainActor in
                            do {
                                try await Task.sleep(for: .seconds(self.shortPauseThreshold))
                                // print("🔇 [LiveMic] Short pause detected after \(self.shortPauseThreshold)s (UI feedback only)")
                            } catch {
                                // Timer was cancelled (user spoke again)
                            }
                        }

                        // Long pause timer: Stop mic and signal end-of-turn to Gemini
                        self.longPauseTimer = Task { @MainActor in
                            do {
                                try await Task.sleep(for: .seconds(self.longPauseThreshold))

                                // Check if mic is still running (might have been stopped by Gemini responding)
                                guard self.isRunning else {
                                    // print("⏹️ [LiveMic] Long pause timer fired but mic already stopped - ignoring")
                                    return
                                }

                                // print("⏹️ [LiveMic] Long pause detected after \(self.longPauseThreshold)s - finalizing turn")

                                // Capture transcript before stopping
                                let finalTranscript = self.lastPrintedTranscript

                                // Stop the mic
                                self.stop()

                                // Notify that the turn is complete with the transcript
                                if !finalTranscript.isEmpty {
                                    self.onTurnComplete?(finalTranscript)
                                }
                            } catch {
                                // Timer was cancelled (user spoke again)
                            }
                        }
                    }
                }
            }

            if let error {
                print("⚠️ [LiveMic] Speech recognition error: \(error.localizedDescription)")
                self.recognitionTask?.cancel()
                self.recognitionTask = nil

                guard self.isRunning else { return }

                self.recognitionRestartTask?.cancel()
                self.recognitionRestartTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: .milliseconds(250))
                    guard self.isRunning else { return }
                    print("🔁 [LiveMic] Restarting speech recognition after transient error")
                    self.startSpeechRecognition()
                }
            }
        }
    }

    private func stopSpeechRecognition() {
        if !lastPrintedTranscript.isEmpty {
            onSpeechEnd?()
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRestartTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        recognitionRestartTask = nil
        lastPrintedTranscript = ""
    }
}
