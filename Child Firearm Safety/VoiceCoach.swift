//
//  VoiceCoach.swift
//  Child Firearm Safety
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

    init(promptKey: String = "systemPrompt") {
        self.systemPrompt = UserDefaults.standard.string(forKey: promptKey) ?? defaultPrompt
        setupMicCallbacks()
    }

    private func setupMicCallbacks() {
        LiveMicController.shared.onSpeechStart = { [weak self] in
            Task { @MainActor in
                guard let self else { return }

                // Ignore speech callbacks if mic was stopped for Gemini's response
                // This prevents buffered speech recognition from restarting the mic
                if self.micStoppedForCurrentTurn {
                    print("🎙️ [VC] Speech detected but ignoring (Gemini is responding)")
                    return
                }

                // Keep state as .listening - we're continuously streaming audio to Gemini
                if self.state != .speaking {
                    self.state = .listening
                }
                print("🎙️ [VC] User started speaking")
            }
        }

        LiveMicController.shared.onSpeechEnd = { [weak self] in
            Task { @MainActor in
                guard let self else { return }

                // Ignore if Gemini is responding
                if self.micStoppedForCurrentTurn {
                    return
                }

                // With continuous streaming, don't change state on pause detection
                // The state will change to .thinking/.speaking when Gemini actually responds
                print("🔇 [VC] User paused speaking (audio still streaming to Gemini)")
            }
        }

        LiveMicController.shared.onError = { [weak self] error in
            Task { @MainActor in
                self?.transcript.append("\n[mic error] \(error.localizedDescription)")
            }
        }

        LiveMicController.shared.onTurnComplete = { [weak self] userTranscript in
            Task { @MainActor in
                guard let self else { return }

                // Ignore if we already stopped for Gemini's response
                if self.micStoppedForCurrentTurn {
                    print("⚠️ [VC] Turn complete callback ignored - mic already stopped for Gemini's response")
                    return
                }

                // Ignore if conversation isn't active (might be shutting down)
                if !self.isConversationActive {
                    print("⚠️ [VC] Turn complete callback ignored - conversation not active")
                    return
                }

                // Ignore if a turn is already in flight
                if self.isTurnInFlight {
                    print("⚠️ [VC] Turn complete callback ignored - turn already in flight")
                    return
                }

                print("📝 [VC] Turn complete with transcript: \(userTranscript)")
                self.state = .thinking
                self.isTurnInFlight = true

                // Send the transcript to Gemini to explicitly signal end-of-turn
                // This helps trigger Gemini's response since its VAD doesn't always work
                await self.live.sendText("User said: \(userTranscript)")
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
                try AudioSessionManager.shared.configure(for: .duplexVoice)
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
                    self.liveAudio.resetForNewTurn()  // Reset buffer tracking for new turn
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

                    // Wait for audio playback to finish before starting to listen
                    self.liveAudio.onPlaybackComplete { [weak self] in
                        Task { @MainActor in
                            guard let self else { return }
                            print("✅ [VC] intro playback complete, starting conversation")
                            self.resumeListening()
                        }
                    }
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
                    self.liveAudio.resetForNewTurn()  // Reset buffer tracking for new turn
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
                // Audio operations now run on background queues to avoid blocking main thread
                guard let self else { return }

                // Gate the mic so the model does not hear its own audio.
                Task { @MainActor in
                    if !self.micStoppedForCurrentTurn {
                        print("🔇 [VC] Stopping mic - Gemini is responding")
                        self.micStoppedForCurrentTurn = true
                        // Brief thinking state while transitioning from listening to speaking
                        self.state = .thinking
                        try? AudioSessionManager.shared.configure(for: .playbackOnly)
                    }
                }

                // Stop mic on background (now thread-safe)
                LiveMicController.shared.stop()

                // Play audio on background (now thread-safe)
                self.playLiveAudio(data: data, sampleRate: rate)
            },
            onDone: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.llmActive = false
                    self.isTurnInFlight = false
                    self.isConversationActive = false
                    self.micStoppedForCurrentTurn = false
                    print("✅ [VC] audio turn complete (model done sending)")

                    // Wait for ALL audio playback to finish before resuming mic
                    self.liveAudio.onPlaybackComplete { [weak self] in
                        Task { @MainActor in
                            guard let self else { return }
                            print("✅ [VC] audio playback complete, waiting for echo to subside...")
                            try? await Task.sleep(for: .milliseconds(1000))
                            print("✅ [VC] resuming mic after echo delay")
                            self.resumeListening()
                        }
                    }
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

        // Update state on main thread (required for @Published property)
        Task { @MainActor in
            self.state = .speaking
        }

        // Audio playback now runs on background queue (inside LiveAudioPlayer)
        liveAudio.playPCM16(data, sampleRate: sampleRate)
    }

    private func resumeListening() {
        // Prevent multiple simultaneous conversations
        guard !isConversationActive else {
            print("⚠️ [VC] audio conversation already active, skipping resumeListening")
            return
        }

        try? AudioSessionManager.shared.configure(for: .duplexVoice)
        isConversationActive = true
        state = .listening
        VoicePerms.setModeListening()

        // Start audio conversation (which internally calls LiveMicController.shared.startStreaming)
        // The startStreaming method now runs engine operations on background queue
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
