//
//  VoiceCoach.swift
//  Child Gun Safety
//
//  Simplified: scripted intro + audio-only Live conversation with VAD.
//

import Foundation
import AVFoundation
import Speech

@MainActor
final class VoiceCoach: ObservableObject {
    enum State { case idle, listening, thinking, speaking }
    @Published private(set) var state: State = .idle
    @Published var transcript: String = ""   // for UI

    // Socratic, question-forward system prompt.
    private let systemPrompt = """
    You are a child‑safety coach guiding a young learner to *say the safe plan in their own words*.

    Core rules (never state as commands; elicit them through questions):
    • Don't touch it. • Move away. • Tell a trusted adult.

    Style:
    - Be Socratic. Ask one short, concrete question at a time (6–14 words).
    - Avoid didactic language, instructions, or judgments. Do **not** say "you should…".
    - Default to a single sentence. Only add a brief affirmation like "Nice thinking." when helpful.
    - Never explain how to operate, handle, or identify a firearm or any weapon.
    - If the child asks "What do I do?" respond with a guiding question that leads them to name the three steps.
    - Prefer neutral phrasing like "something that might be unsafe" unless the child names the object.
    - Keep the conversation moving: acknowledge briefly, then ask a follow‑up question.
    - Do not ask about body positioning or hands unless the child explicitly asks; focus only on the three rules.
    - No lists in outputs; no emojis; no role‑play beyond being a calm coach.

    Your objective is to help the child independently state: don't touch it, move away, and tell a trusted adult. Stay concise and question‑forward at all times.
    """

    private lazy var live = GeminiFlashLiveClient(systemInstruction: systemPrompt)
    private let liveAudio = LiveAudioPlayer.shared

    private var liveHandle: GeminiFlashLiveStreamHandle?
    private var isTurnInFlight = false
    private var isConversationActive = false

    // Lifecycle flag to coordinate LLM streaming and playback
    private var llmActive = false

    init() {
        setupMicCallbacks()
    }

    private func setupMicCallbacks() {
        LiveMicController.shared.onSpeechStart = { [weak self] in
            Task { @MainActor in
                self?.state = .listening
                print("🎙️ [VC] User started speaking")
            }
        }
        
        LiveMicController.shared.onSpeechEnd = { [weak self] in
            Task { @MainActor in
                self?.state = .thinking
                print("🔇 [VC] User stopped speaking, waiting for response...")
            }
        }
        
        LiveMicController.shared.onError = { [weak self] error in
            Task { @MainActor in
                self?.transcript.append("\n[mic error] \(error.localizedDescription)")
            }
        }
    }

    /// Stop any ongoing LLM streaming, mic input, and audio playback.
    private func interruptLLMAndTTS() {
        cancelStream()
        liveAudio.stop()
        LiveMicController.shared.stop()
        llmActive = false
        isTurnInFlight = false
        isConversationActive = false
    }

    func startSession() {
        Task { @MainActor in
            do {
                try VoicePerms.activateAudioSession()
                try await VoicePerms.requestMicrophone()
                try await VoicePerms.requestSpeech()
                VoicePerms.setModeListening()

                // Begin with the scripted intro spoken by the Live model.
                scriptedIntro()
            } catch {
                transcript.append("\n[voice error] \(error.localizedDescription)")
                state = .idle
            }
        }
    }

    func stopSession() {
        LiveMicController.shared.stop()
        cancelStream()
        liveAudio.stop()
        live.shutdown()
        isConversationActive = false
        state = .idle
    }

    /// Common logging + guard to avoid sending duplicate turns to the Live model.
    /// Returns false if a turn is already in flight.
    private func beginTurn(kind: String, prompt: String) -> Bool {
        if isTurnInFlight {
            print("⏭️ [VC] \(kind) turn skipped; another turn is already in flight")
            return false
        }
        isTurnInFlight = true
        print("🧵 [VC] \(kind) → LLM:\n\(prompt)")
        return true
    }

    /// Play a short, scripted intro via the Live model, then hand off to Live mic streaming.
    private func scriptedIntro() {
        Task { @MainActor in
            interruptLLMAndTTS()
            print("[VC] scriptedIntro: begin")

            // Keep this concise and neutral; do not teach handling, only frame the activity.
            let intro = "Hi there. Let's do a quick safety practice. Your friend needs help looking for their phone. Take a look around the room."

            // Ask the Live model to say this line to the child, then stop.
            let userText = "You are starting the practice. Say this to the child, then stop: \"\(intro)\""

            // Log + guard against duplicate sends
            guard self.beginTurn(kind: "intro", prompt: userText) else { return }

            state = .thinking
            liveHandle = live.stream(userText: userText, handlers: introLiveHandlers())
        }
    }

    private func introLiveHandlers() -> GeminiFlashLiveClient.Handlers {
        GeminiFlashLiveClient.Handlers(
            onOpen: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.llmActive = true
                    self.append("\nCoach: ")
                }
            },
            onTextDelta: { [weak self] chunk in
                Task { @MainActor in
                    print("🟩 [LLM ←] \(chunk)")
                    self?.append(chunk)
                }
            },
            onAudioReady: { [weak self] data, rate in
                Task { @MainActor in self?.playLiveAudio(data: data, sampleRate: rate) }
            },
            onDone: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.llmActive = false
                    self.isTurnInFlight = false
                    // After the intro finishes, start listening to the child via the live mic.
                    self.resumeListening()
                }
            },
            onError: { [weak self] err in
                Task { @MainActor in
                    guard let self else { return }
                    self.llmActive = false
                    self.isTurnInFlight = false
                    self.append("\n[error] \(err.localizedDescription)")
                    self.liveAudio.stop()
                    self.resumeListening()
                }
            }
        )
    }

    private func cancelStream() {
        liveHandle?.cancel()
        liveHandle = nil
    }

    private func audioConversationHandlers() -> GeminiFlashLiveClient.Handlers {
        GeminiFlashLiveClient.Handlers(
            onOpen: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.llmActive = true
                    print("🧵 [VC] audio conversation open → starting mic")
                    // CRITICAL: Pass the correct client instance!
                    LiveMicController.shared.startStreaming(to: self.live)
                }
            },
            onTextDelta: { [weak self] chunk in
                Task { @MainActor in
                    print("🟩 [LLM ←] \(chunk)")
                    self?.append(chunk)
                }
            },
            onAudioReady: { [weak self] data, rate in
                Task { @MainActor in
                    self?.playLiveAudio(data: data, sampleRate: rate)
                }
            },
            onDone: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.llmActive = false
                    self.isTurnInFlight = false
                    self.isConversationActive = false
                    print("✅ [VC] audio turn complete")
                    
                    // After the model responds, resume listening for the next utterance
                    // Add a small delay to avoid immediate re-triggering
                    try? await Task.sleep(for: .milliseconds(500))
                    self.resumeListening()
                }
            },
            onError: { [weak self] err in
                Task { @MainActor in
                    guard let self else { return }
                    self.llmActive = false
                    self.isTurnInFlight = false
                    self.isConversationActive = false
                    self.append("\n[error] \(err.localizedDescription)")
                    self.liveAudio.stop()
                    LiveMicController.shared.stop()
                }
            }
        )
    }

    private func playLiveAudio(data: Data, sampleRate: Double) {
        guard !data.isEmpty else { return }
        state = .speaking
        liveAudio.playPCM16(data, sampleRate: sampleRate)
    }

    private func resumeListening() {
        // Prevent multiple simultaneous conversations
        guard !isConversationActive else {
            print("⚠️ [VC] audio conversation already active, skipping resumeListening")
            return
        }
        
        isConversationActive = true
        state = .listening
        VoicePerms.setModeListening()
        liveHandle = live.startAudioConversation(handlers: audioConversationHandlers())
    }

    private func append(_ s: String) { transcript += s }

    // For the "Ping LLM" test button (still useful for quick text-only checks).
    func handleTestPrompt(_ text: String) {
        transcript.append("\n\nYou: \(text)")
        let userText = text
        guard beginTurn(kind: "test", prompt: userText) else { return }
        state = .thinking
        liveHandle = live.stream(userText: userText, handlers: audioConversationHandlers())
    }
}
