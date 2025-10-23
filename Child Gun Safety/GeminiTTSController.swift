//
//  GeminiTTSController.swift
//  Child Gun Safety
//
//  Created by Max on 10/19/25.
//

//
//  GeminiTTSController.swift
//  Child Gun Safety
//
//  Requires: iOS 15+, AVFoundation
//

import Foundation
import AVFoundation
import FirebaseAI  // Add this import

@MainActor
final class GeminiTTSController {

    // Pick the TTS model. Pro is the most realistic; Flash is cheaper/faster.
    // Other valid option: "gemini-2.5-pro-preview-tts"
    private let modelName = "gemini-2.5-flash-preview-tts"

    // Voices: "Kore", "Puck", "Zephyr", "Charon", ... (see docs)
    // You can expose this as a user setting.
    var voiceName: String = "Kore"
    
    // --- Lifecycle callbacks (so VoiceCoach/SpeechDirector can react) ---
    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?
    private(set) var isSpeaking: Bool = false

    // --- Streaming queue for sentence-sized chunks ---
    private var queue: [String] = []
    private var draining = false

    // --- Batching & rate limiting (free tier friendly) ---
    private let batchSentenceCap: Int = 3              // max sentences per TTS request
    private let batchCharCap: Int = 400                // soft character cap per batch
    private let minSecondsBetweenRequests: TimeInterval = 12 // ~5 RPM safety
    private var lastTTSTime: Date? = nil

    // --- Networking diagnostics & fallback ---
    private let requestTimeout: TimeInterval = 8
    var allowAppleFallback: Bool = true
    private var appleSynth: AVSpeechSynthesizer? = nil
    private var appleDelegate: AppleSynthDelegateProxy?

    // Audio engine pieces
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?

    // Initialize Firebase AI service (do this once, e.g., in init or app startup)
    private lazy var aiService: FirebaseAI = {
        return FirebaseAI.firebaseAI(backend: .googleAI())  // Or .vertexAI(location: "us-central1") for production
    }()

    private func makeModel() -> GenerativeModel {
        let generationConfig = GenerationConfig(
            responseMIMEType: "audio/pcm;rate=24000"
        )

        let requestOptions = RequestOptions(timeout: requestTimeout)

        let instructionText = "You are a text-to-speech synthesizer. Speak using the \(voiceName) voice. Only return audio for the provided text."
        let systemInstruction = ModelContent(role: "system", parts: [TextPart(instructionText)])

        return aiService.generativeModel(
            modelName: modelName,
            generationConfig: generationConfig,
            systemInstruction: systemInstruction,
            requestOptions: requestOptions
        )
    }

    /// Enqueue a sentence for sequential playback (used for streaming LLM output).
    func enqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.append(trimmed)
        if !draining && !isSpeaking {
            draining = true
            Task { @MainActor in await drainQueue() }
        }
    }

    private func dequeue() -> String? {
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    /// Ensures we don't exceed free-tier RPM by spacing TTS requests.
    private func enforceRateLimitIfNeeded() async {
        if let last = lastTTSTime {
            let delta = Date().timeIntervalSince(last)
            if delta < minSecondsBetweenRequests {
                let wait = minSecondsBetweenRequests - delta
                let ns = UInt64(wait * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    private func drainQueue() async {
        while !queue.isEmpty {
            var batchText = ""
            var sentences = 0
            while !queue.isEmpty && sentences < batchSentenceCap {
                let next = queue.first!
                let projectedCount = batchText.isEmpty ? next.count : (batchText.count + 1 + next.count)
                if projectedCount > batchCharCap && sentences > 0 {
                    break
                }
                _ = queue.removeFirst()
                batchText += (batchText.isEmpty ? "" : " ") + next
                sentences += 1
            }
            // Speak the batched text without interrupting ongoing playback
            try? await speak(batchText, interrupt: false)
        }
        draining = false
    }

    /// Speak text using Gemini TTS.
    /// - Parameter interrupt: when true, cancels any current playback and clears queued sentences.
    func speak(_ text: String, interrupt: Bool = true) async throws {
        if interrupt {
            // Clear queued sentences and stop current audio for barge-in behavior
            queue.removeAll(keepingCapacity: false)
            stop()
        }
        // Respect free-tier rate limits
        await enforceRateLimitIfNeeded()
        lastTTSTime = Date()
        print("[TTS] request -> len=\(text.count)")

        do {
            // Prepare content and config for TTS
            let content = ModelContent(parts: [TextPart(text)])

            // Call generateContent for audio response
            let response = try await makeModel().generateContent([content])

            guard let audioPart = response.inlineDataParts.first else {
                throw NSError(domain: "GeminiTTS", code: 2, userInfo: [NSLocalizedDescriptionKey: "No audio returned"])
            }

            let pcm = audioPart.data

            print("[TTS] received PCM bytes: \(pcm.count)")
            // PCM is 24_000 Hz, mono, 16-bit little-endian (per docs).
            // Build an AVAudioPCMBuffer and play it via AVAudioEngine.
            try playPCM16Mono24000(pcm)
        } catch {
            print("[TTS] error -> \(error.localizedDescription)")
            if allowAppleFallback {
                print("[TTS] falling back to AVSpeechSynthesizer")
                speakApple(text)
                return
            } else {
                throw error
            }
        }
    }

    /// Stop current playback.
    func stop() {
        if let synth = appleSynth, synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        do {
            if AVAudioSession.sharedInstance().isOtherAudioPlaying == false {
                try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            }
        } catch {
            // Non-fatal; keep going
        }
        // Also drop pending sentences (barge-in)
        queue.removeAll(keepingCapacity: false)
        let wasSpeaking = isSpeaking
        player?.stop()
        engine?.stop()
        engine?.reset()
        player = nil
        engine = nil
        if wasSpeaking {
            isSpeaking = false
            Task { @MainActor in self.onFinish?() }
        }
    }

    // MARK: - Audio plumbing

    private func playPCM16Mono24000(_ pcm: Data) throws {
        let sampleRate: Double = 24_000
        let channelCount: AVAudioChannelCount = 1
        let commonFormat = AVAudioCommonFormat.pcmFormatInt16

        guard let fmt = AVAudioFormat(commonFormat: commonFormat,
                                      sampleRate: sampleRate,
                                      channels: channelCount,
                                      interleaved: true) else {
            throw NSError(domain: "GeminiTTS", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create audio format"])
        }
        self.format = fmt

        // Create engine and player
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)

        // Convert Data -> AVAudioPCMBuffer
        let frameLength = UInt32(pcm.count / 2) // 16-bit samples
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameLength) else {
            throw NSError(domain: "GeminiTTS", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate audio buffer"])
        }
        buffer.frameLength = frameLength

        // Copy bytes into buffer
        pcm.withUnsafeBytes { rawBuf in
            if let dst = buffer.int16ChannelData?.pointee {
                dst.update(from: rawBuf.bindMemory(to: Int16.self).baseAddress!,
                           count: Int(frameLength))
            }
        }

        // Notify start just before playback kicks off
        isSpeaking = true
        Task { @MainActor in self.onStart?() }

        try engine.start()
        player.play()
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            // Playback finished
            Task { @MainActor in
                guard let self = self else { return }
                self.isSpeaking = false
                self.onFinish?()
                self.stop()
            }
        }

        self.engine = engine
        self.player = player
    }
    // MARK: - Apple TTS delegate proxy (avoids @MainActor conformance issues)
    private final class AppleSynthDelegateProxy: NSObject, AVSpeechSynthesizerDelegate {
        weak var owner: GeminiTTSController?
        init(owner: GeminiTTSController) { self.owner = owner }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            Task { @MainActor in
                guard let o = self.owner else { return }
                o.isSpeaking = false
                o.onFinish?()
            }
        }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            Task { @MainActor in
                guard let o = self.owner else { return }
                o.isSpeaking = false
                o.onFinish?()
            }
        }
    }
    // MARK: - Apple fallback
    private func speakApple(_ text: String) {
        if appleSynth == nil {
            appleSynth = AVSpeechSynthesizer()
        }
        if appleDelegate == nil {
            appleDelegate = AppleSynthDelegateProxy(owner: self)
        }
        appleSynth?.delegate = appleDelegate
        // Ensure audio routes to the speaker even if the ringer is muted
        do {
            let session = AVAudioSession.sharedInstance()
            // Use playback here (ASR is paused during scripted intro); default to speaker
            try session.setCategory(.playback, options: [.defaultToSpeaker, .duckOthers, .allowBluetooth])
            try session.setActive(true, options: [])
        } catch {
            print("[TTS] AVAudioSession (playback) error: \(error.localizedDescription)")
        }
        let utt = AVSpeechUtterance(string: text)
        utt.rate = AVSpeechUtteranceDefaultSpeechRate
        isSpeaking = true
        onStart?()
        appleSynth?.speak(utt)
    }
}
