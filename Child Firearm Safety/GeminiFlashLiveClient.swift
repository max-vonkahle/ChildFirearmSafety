//
//  GeminiFlashLiveClient.swift
//  Child Firearm Safety
//
//  Live Gemini (flash) client that streams text + audio via FirebaseAI.
//

import Foundation
import FirebaseAILogic

@MainActor
final class GeminiFlashLiveStreamHandle {
    fileprivate var onCancel: (() -> Void)?

    func cancel() {
        onCancel?()
    }
}

@MainActor
final class GeminiFlashLiveClient {

    /// Callbacks for a single live turn.
    struct Handlers {
        /// Called once the live session is ready and the prompt has been sent.
        var onOpen: (() -> Void)?

        /// Called with incremental text as it arrives (either direct model tokens
        /// or the transcription of the audio output).
        var onTextDelta: ((String) -> Void)?

        /// Called once per turn when audio for that turn is fully ready.
        /// - Parameters:
        ///   - data: Raw audio bytes (typically 16-bit PCM).
        ///   - sampleRate: Sample rate in Hz (e.g., 16_000 or 24_000).
        var onAudioReady: ((Data, Double) -> Void)?

        /// Called when the turn is finished (either naturally or after interruption).
        var onDone: (() -> Void)?

        /// Called on any error during the session or streaming.
        var onError: ((Error) -> Void)?
    }

    /// Singleton for most use-cases.
    static let shared = GeminiFlashLiveClient()

    // MARK: - Configuration

    private let modelName: String
    private let voiceName: String
    private let temperature: Float
    private let systemInstructionText: String?

    private lazy var aiService: FirebaseAI = {
        FirebaseAI.firebaseAI(backend: .googleAI())
    }()

    private var liveModel: LiveGenerativeModel?
    private var session: LiveSession? {
        didSet {
            #if DEBUG
            if session == nil && oldValue != nil {
                // Session closed - this is normal during shutdown
                print("✅ [Live] Session closed gracefully")
            }
            #endif
        }
    }
    private var responseTask: Task<Void, Never>?

    private var currentHandlers: Handlers?
    private var pendingAudio = Data()
    private var pendingSampleRate: Double = 24_000

    init(
        modelName: String = "gemini-2.5-flash-native-audio-preview-12-2025",
        voiceName: String = "Puck",
        temperature: Float = 0.2,
        systemInstruction: String? = nil
    ) {
        self.modelName = modelName
        self.voiceName = voiceName
        self.temperature = temperature
        self.systemInstructionText = systemInstruction
    }

    deinit {
        responseTask?.cancel()
        if let session {
            Task { await session.close() }
        }
    }

    // MARK: - Public API

    /// Start a new live turn with the given user text.
    /// Returns a handle you can use to cancel / barge-in.
    @discardableResult
    func stream(userText: String, handlers: Handlers) -> GeminiFlashLiveStreamHandle {
        print("🟦 [LLM →] \(userText)")
        
        let handle = GeminiFlashLiveStreamHandle()

        handle.onCancel = { [weak self] in
            Task { [weak self] in
                await self?.interruptActiveTurn()
            }
        }

        Task { [weak self] in
            await self?.startStreaming(userText: userText, handlers: handlers)
        }

        return handle
    }

    /// Start a new live turn that will be driven by microphone/audio input.
    /// The model will respond with streaming audio (and optional text tokens).
    /// Use `sendAudioChunk(_:)` to send recorded PCM chunks to the model.
    @discardableResult
    func startAudioConversation(handlers: Handlers) -> GeminiFlashLiveStreamHandle {
        let handle = GeminiFlashLiveStreamHandle()

        handle.onCancel = { [weak self] in
            Task { [weak self] in
                await self?.interruptActiveTurn()
            }
        }

        Task { [weak self] in
            await self?.startAudioConversationInternal(handlers: handlers)
        }

        return handle
    }

    /// Send a chunk of 16-bit PCM mono audio (for example, from the microphone)
    /// to the live session. The sample rate should match what the backend expects
    /// (typically 24_000 Hz for `audio/pcm;rate=24000`).
    @MainActor
    func sendAudioChunk(_ data: Data) async {
        guard let session else {
            #if DEBUG
            print("🟥 [Live] sendAudioChunk called but session is nil - session was: \(self.session == nil ? "nil" : "exists"), liveModel: \(liveModel == nil ? "nil" : "exists")")
            #endif
            return
        }

        #if DEBUG
        // Only print occasionally to reduce log spam
        if Int.random(in: 0..<100) == 0 {
            print("🎙 [Live] sending audio chunk: \(data.count) bytes")
        }
        #endif
        
        await session.sendAudioRealtime(data)
    }

    /// Internal helper to start an audio-driven turn (no initial text).
    private func startAudioConversationInternal(handlers: Handlers) async {
        do {
            // Reuse existing session or create a new one
            // Don't call ensureSession if we're in the middle of a response
            if session == nil {
                try await ensureSession()
            }
            try Task.checkCancellation()

            // Wait a brief moment to ensure session is fully ready
            try await Task.sleep(for: .milliseconds(100))
            
            guard session != nil else {
                throw NSError(domain: "GeminiLive", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Session failed to initialize"])
            }

            currentHandlers = handlers
            pendingAudio.removeAll(keepingCapacity: false)
            pendingSampleRate = 24_000

            print("✅ [Live] Audio conversation session ready (session exists: \(session != nil))")
            handlers.onOpen?()
        } catch {
            print("🟥 [Live] Failed to start audio conversation: \(error)")
            handlers.onError?(error)
            currentHandlers = nil
        }
    }

    /// Close the live session and drop any pending state.
    func shutdown() {
        responseTask?.cancel()
        responseTask = nil
        let session = self.session
        self.session = nil
        pendingAudio.removeAll(keepingCapacity: false)
        currentHandlers = nil
        if let session {
            Task { await session.close() }
        }
    }

    // MARK: - Internal streaming logic

    private func startStreaming(userText: String, handlers: Handlers) async {
        do {
            try await ensureSession()
            try Task.checkCancellation()

            currentHandlers = handlers
            pendingAudio.removeAll(keepingCapacity: false)
            pendingSampleRate = 24_000

            handlers.onOpen?()

            // Send the user text using the Live API helper.
            if let session {
                await session.sendTextRealtime(userText)
            }

        } catch {
            handlers.onError?(error)
            currentHandlers = nil
        }
    }

    /// Ensure we have an active live session connected.
    private func ensureSession() async throws {
        if session != nil { return }

        // Minimal LiveGenerationConfig aligned with Firebase Live API docs:
        // - Live-capable model (e.g. gemini-live-2.5-flash-preview)
        // - Audio response modality only
        let generation = LiveGenerationConfig(
            responseModalities: [.audio]
        )

        // Optional system instruction; sent as initial system content.
        let systemInstruction = systemInstructionText.map { text in
            ModelContent(role: "system", parts: [TextPart(text)])
        }
        
        // Debug logging:
        // print("🟣 [Live] connecting live model:", modelName)

        let model = aiService.liveModel(
            modelName: modelName,
            generationConfig: generation,
            systemInstruction: systemInstruction
        )

        let session = try await model.connect()
        liveModel = model
        self.session = session
        listenForResponses(session: session)
    }

    private func listenForResponses(session: LiveSession) {
        responseTask?.cancel()
        responseTask = Task { [weak self] in
            do {
                for try await message in session.responses {
                    guard let self else { return }
                    await self.handle(message: message)
                }
            } catch {
                await self?.handleStreamError(error)
            }
        }
    }

    // MARK: - Message handling

    private func handle(message: LiveServerMessage) {
        guard let handlers = currentHandlers else {
            #if DEBUG
            print("⚠️ [Live] Message received but no handlers set - ignoring")
            #endif
            return
        }

        switch message.payload {
        case .content(let serverContent):

            // High-level info for each content message
            #if DEBUG
            print("🟣 [Live] content: modelTurn? \(serverContent.modelTurn != nil), turnComplete: \(serverContent.isTurnComplete)")
            #endif

            // 1) Model turn content, if present.
            if let turn = serverContent.modelTurn {
                #if DEBUG
                // print("🟣 [Live] NEW MODEL TURN (parts: \(turn.parts.count))")
                #endif

                #if DEBUG
                // print("🟣 [Live] modelTurn parts count: \(turn.parts.count)")
                #endif

                for part in turn.parts {
                    if let textPart = part as? TextPart {
                        // Plain text token/turn
                        #if DEBUG
                        print("🟩 [LLM ← text] \(textPart.text)")
                        #endif
                        handlers.onTextDelta?(textPart.text)

                    } else if let inlinePart = part as? InlineDataPart {
                        // Audio bytes, e.g. "audio/pcm;rate=24000"
                        let mime = inlinePart.mimeType.lowercased()
                        if mime.hasPrefix("audio/pcm") {
                            let rate = Self.sampleRate(from: inlinePart.mimeType) ?? 24_000
                            #if DEBUG
                            print("🔊 [LLM ← audio] \(inlinePart.data.count) bytes @ \(rate) Hz")
                            #endif
                            pendingSampleRate = rate
                            pendingAudio.append(inlinePart.data)
                            handlers.onAudioReady?(inlinePart.data, rate)
                        } else {
                            #if DEBUG
                            // print("🟡 [Live] inline data (non-audio) mime=\(inlinePart.mimeType)")
                            #endif
                        }
                        #if DEBUG
                        // print("🔍 [Live] Model audio part: \(inlinePart.mimeType), bytes: \(inlinePart.data.count)")
                        #endif
                    } else {
                        #if DEBUG
                        // print("🟡 [Live] ignored part type:", type(of: part))
                        #endif
                    }
                }
            } else {
                // No modelTurn at all – useful to know!
                #if DEBUG
                // print("🟥 [Live] content with NO modelTurn")
                #endif
            }

            if serverContent.isTurnComplete {
                #if DEBUG
                // print("🟣 [Live] MODEL TURN COMPLETE — buffered audio size: \(pendingAudio.count) bytes at \(pendingSampleRate) Hz")
                #endif
                pendingAudio.removeAll(keepingCapacity: false)
                #if DEBUG
                print("✅ [Live] turn complete")
                #endif
                let doneHandler = currentHandlers?.onDone
                currentHandlers = nil
                // Call onDone after clearing handlers to avoid re-entrancy issues
                doneHandler?()
            }

        case .goingAwayNotice:
            #if DEBUG
            print("🟥 [Live] goingAwayNotice (session closing)")
            #endif
            currentHandlers?.onDone?()
            currentHandlers = nil

        case .toolCall, .toolCallCancellation:
            // Not used yet; ignore.
            break
        }
    }

    // MARK: - Error / interruption helpers

    private func handleStreamError(_ error: Error) {
        #if DEBUG
        print("❗ [Live] stream error: \(error)")
        #endif

        if let handlers = currentHandlers {
            handlers.onError?(error)
        }
        currentHandlers = nil
        pendingAudio.removeAll(keepingCapacity: false)

        // Fully tear down the live session on error so the next turn
        // starts from a clean state.
        let oldSession = session
        session = nil
        liveModel = nil
        if let oldSession {
            Task { await oldSession.close() }
        }
    }

    private func interruptActiveTurn() async {
        // Cancel any in-flight handlers and clear pending audio, then
        // cleanly close the current live session so the next turn can
        // re-establish a fresh connection.
        currentHandlers = nil
        pendingAudio.removeAll(keepingCapacity: false)

        let oldSession = session
        session = nil
        liveModel = nil
        if let oldSession {
            await oldSession.close()
        }
    }

    private static func sampleRate(from mimeType: String) -> Double? {
        let components = mimeType.split(separator: ";").dropFirst()
        for component in components {
            let pair = component.split(separator: "=")
            guard pair.count == 2 else { continue }
            let key = pair[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = pair[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "rate" || key == "samplerate" || key == "sample_rate" {
                return Double(value)
            }
        }
        return nil
    }
}
