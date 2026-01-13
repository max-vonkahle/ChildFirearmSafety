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
    private let defaultPrompt = """
    You are a child‑safety coach guiding a young learner to stay safe if they find a firearm.

    Core rules that you are trying to instill in them:
    • Stop. • Don't touch it. • Run away. • Tell a trusted adult.

    Your are guiding them through a behavioral skills training where they will see a gun.
    You want to teach them the core rules, then have them repeat them as well as act them out. Make sure that they answer your questions correctly and repeat the correct steps. 

    Your objective is to help the child learn: stop, don't touch it, run away, and tell a trusted adult.
    """

    private let systemPrompt: String

    private lazy var live = GeminiFlashLiveClient(systemInstruction: systemPrompt)
    private let liveAudio = LiveAudioPlayer.shared

    private var liveHandle: GeminiFlashLiveStreamHandle?
    private var isTurnInFlight = false
    private var isConversationActive = false
    private var micStoppedForCurrentTurn = false

    // Lifecycle flag to coordinate LLM streaming and playback
    private var llmActive = false

    init() {
        self.systemPrompt = UserDefaults.standard.string(forKey: "systemPrompt") ?? defaultPrompt
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
        micStoppedForCurrentTurn = false
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
        micStoppedForCurrentTurn = false
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
            let intro = "Hi there. Let's do a quick safety practice. Can you show me what you learned if you find a gun like this?"

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
                    guard let self else { return }
                    // Gate the mic so the model does not hear its own audio.
                    if !self.micStoppedForCurrentTurn {
                        print("🔇 [VC] Stopping mic for model audio")
                        LiveMicController.shared.stop()
                        self.micStoppedForCurrentTurn = true
                    }
                    self.playLiveAudio(data: data, sampleRate: rate)
                }
            },
            onDone: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.llmActive = false
                    self.isTurnInFlight = false
                    self.isConversationActive = false
                    self.micStoppedForCurrentTurn = false
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
                    self.micStoppedForCurrentTurn = false
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
