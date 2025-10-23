//
//  GeminiFlashLiveClient.swift
//  Child Gun Safety
//
//  Created by OpenAI Assistant.
//

import Foundation
import FirebaseAI

@MainActor
final class GeminiFlashLiveStreamHandle {
    fileprivate var onCancel: (() -> Void)?

    func cancel() {
        onCancel?()
    }
}

@MainActor
final class GeminiFlashLiveClient {
    struct Handlers {
        var onOpen: (() -> Void)?
        var onTextDelta: ((String) -> Void)?
        var onAudioReady: ((Data, Double) -> Void)?
        var onDone: (() -> Void)?
        var onError: ((Error) -> Void)?
    }

    private let modelName: String
    private let voiceName: String
    private let temperature: Float
    private let systemInstructionText: String?

    private lazy var aiService: FirebaseAI = {
        FirebaseAI.firebaseAI(backend: .googleAI())
    }()

    private var liveModel: LiveGenerativeModel?
    private var session: LiveSession?
    private var responseTask: Task<Void, Never>?

    private var currentHandlers: Handlers?
    private var pendingAudio = Data()
    private var pendingSampleRate: Double = 16_000

    init(modelName: String = "gemini-2.0-flash-live",
         voiceName: String = "Kore",
         temperature: Float = 0.2,
         systemInstruction: String? = nil) {
        self.modelName = modelName
        self.voiceName = voiceName
        self.temperature = temperature
        self.systemInstructionText = systemInstruction
    }

    deinit {
        responseTask?.cancel()
        if let session { Task { await session.close() } }
    }

    func stream(userText: String, handlers: Handlers) -> GeminiFlashLiveStreamHandle {
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

    private func startStreaming(userText: String, handlers: Handlers) async {
        do {
            try await ensureSession()
            try Task.checkCancellation()
            currentHandlers = handlers
            pendingAudio.removeAll(keepingCapacity: false)
            pendingSampleRate = 16_000
            handlers.onOpen?()
            await session?.sendContent(userText, turnComplete: true)
        } catch {
            handlers.onError?(error)
            currentHandlers = nil
        }
    }

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

    private func ensureSession() async throws {
        if session != nil { return }

        let speech = SpeechConfig(voiceName: voiceName)
        let generation = LiveGenerationConfig(
            temperature: temperature,
            responseModalities: [.audio, .text],
            speech: speech,
            outputAudioTranscription: AudioTranscriptionConfig()
        )

        let systemInstruction = systemInstructionText.map { text in
            ModelContent(role: "system", parts: [TextPart(text)])
        }

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

    private func handle(message: LiveServerMessage) {
        guard var handlers = currentHandlers else { return }

        switch message.payload {
        case .content(let content):
            if let turn = content.modelTurn {
                for part in turn.parts {
                    if let textPart = part as? TextPart {
                        handlers.onTextDelta?(textPart.text)
                    } else if let inline = part as? InlineDataPart,
                              inline.mimeType.lowercased().hasPrefix("audio/") {
                        if let rate = Self.sampleRate(from: inline.mimeType) {
                            pendingSampleRate = rate
                        }
                        pendingAudio.append(inline.data)
                    }
                }
            }

            if let transcript = content.outputAudioTranscription?.text,
               !transcript.isEmpty {
                handlers.onTextDelta?(transcript)
            }

            if content.wasInterrupted {
                pendingAudio.removeAll(keepingCapacity: false)
            }

            if content.isTurnComplete || content.wasInterrupted {
                let audio = pendingAudio
                pendingAudio.removeAll(keepingCapacity: false)
                if !audio.isEmpty && content.wasInterrupted == false {
                    handlers.onAudioReady?(audio, pendingSampleRate)
                }
                handlers.onDone?()
                currentHandlers = nil
            } else {
                currentHandlers = handlers
            }
        case .toolCall, .toolCallCancellation:
            break
        case .goingAwayNotice:
            handlers.onError?(NSError(
                domain: "GeminiFlashLive",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Live session ended by server"]
            ))
            currentHandlers = nil
        }
    }

    private func handleStreamError(_ error: Error) {
        if let handlers = currentHandlers {
            handlers.onError?(error)
        }
        currentHandlers = nil
        pendingAudio.removeAll(keepingCapacity: false)
        session = nil
    }

    private func interruptActiveTurn() async {
        currentHandlers = nil
        pendingAudio.removeAll(keepingCapacity: false)
        await session?.sendContent([], turnComplete: false)
    }

    private static func sampleRate(from mimeType: String) -> Double? {
        let components = mimeType.split(separator: ";").dropFirst()
        for component in components {
            let pair = component.split(separator: "=")
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "rate" || key == "samplerate" || key == "sample_rate" {
                return Double(value)
            }
        }
        return nil
    }
}
