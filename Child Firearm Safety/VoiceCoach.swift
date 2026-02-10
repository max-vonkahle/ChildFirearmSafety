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
    private var isProcessingResetInstruction = false
    private var dialogueIntentObserver: NSObjectProtocol?  // Store observer for cleanup

    // Lifecycle flag to coordinate LLM streaming and playback
    private var llmActive = false

    // Unique instance identifier for debugging
    private let instanceID: String

    init(promptKey: String = "systemPrompt") {
        self.systemPrompt = UserDefaults.standard.string(forKey: promptKey) ?? defaultPrompt
        self.instanceID = String(UUID().uuidString.prefix(8))
        print("🎤 [VC INIT] VoiceCoach instance created with ID: \(instanceID), promptKey: \(promptKey)")
        setupMicCallbacks()
        setupDialogueIntentListener()
    }

    deinit {
        // Clean up observer when VoiceCoach is destroyed
        if let observer = dialogueIntentObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        print("🧹 [VC \(instanceID)] VoiceCoach deinitialized and observer removed")
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

    /// Explicitly clean up resources - call this when the view disappears
    func cleanup() {
        print("🧹 [VC \(instanceID)] cleanup() called - removing observers")
        stopSession()
        if let observer = dialogueIntentObserver {
            NotificationCenter.default.removeObserver(observer)
            dialogueIntentObserver = nil
        }
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
            print("[VC \(instanceID)] scriptedIntro: begin")

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

    // MARK: - Dialogue Intent Handling

    private func setupDialogueIntentListener() {
        print("🎧 [VC LISTENER] Setting up dialogue intent listener for instance: \(instanceID)")

        dialogueIntentObserver = NotificationCenter.default.addObserver(
            forName: .vcCommand,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            print("📬 [VC LISTENER \(self.instanceID)] Received .vcCommand notification")
            guard let intent = note.userInfo?[BusKey.dialog] as? DialogueIntent else {
                print("⚠️ [VC LISTENER \(self.instanceID)] Failed to extract intent from notification")
                return
            }
            print("📥 [VC LISTENER \(self.instanceID)] Processing intent: \(intent)")
            // Call directly since we're already on main queue - no Task wrapper needed
            self.handleDialogueIntent(intent)
        }
    }

    private func handleDialogueIntent(_ intent: DialogueIntent) {
        switch intent {
        case .instructReset:
            // Check and set flag synchronously before launching async task
            guard !isProcessingResetInstruction else {
                print("⏭️ [VC] Already processing reset instruction, ignoring duplicate dialogue intent")
                return
            }
            isProcessingResetInstruction = true
            handleResetInstruction()

        case .postResetEncouragement:
            handlePostResetEncouragement()

        default:
            break
        }
    }

    func handleResetInstruction() {
        // Flag already set in handleDialogueIntent
        print("🔄 [VC \(instanceID)] Processing reset instruction")

        let context = """
        The child reached for the gun. Tell them firmly but kindly:
        1. Don't touch it
        2. Step back away from the gun
        3. Go back to where you started
        4. When you're ready, tap anywhere on the screen
        Be encouraging but clear this was incorrect.
        """

        Task { @MainActor in
            // Stop any current conversation or audio to avoid overlap
            LiveMicController.shared.stop()
            liveAudio.stop()
            cancelStream()
            isTurnInFlight = false
            micStoppedForCurrentTurn = false

            // Small delay to ensure cleanup completes
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds

            // Start fresh conversation with reset instruction
            // Use custom handlers that enable tap when audio playback is actually complete
            state = .thinking
            liveHandle = live.stream(userText: context, handlers: resetInstructionHandlers())
        }
    }

    private func resetInstructionHandlers() -> GeminiFlashLiveClient.Handlers {
        GeminiFlashLiveClient.Handlers(
            onOpen: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.llmActive = true
                    self.liveAudio.resetForNewTurn()
                    print("🧵 [VC \(self.instanceID)] Reset instruction streaming started")
                }
            },
            onTextDelta: { [weak self] chunk in
                Task { @MainActor in
                    print("🟩 [LLM ←] \(chunk)")
                    self?.append(chunk)
                }
            },
            onAudioReady: { [weak self] data, rate in
                guard let self else { return }

                // Update state on main thread
                Task { @MainActor in
                    if !self.micStoppedForCurrentTurn {
                        print("🔇 [VC \(self.instanceID)] Stopping mic - model is speaking reset instruction")
                        self.micStoppedForCurrentTurn = true
                        self.state = .speaking
                        try? AudioSessionManager.shared.configure(for: .playbackOnly)
                    }
                }

                // Play audio
                self.playLiveAudio(data: data, sampleRate: rate)
            },
            onDone: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.llmActive = false
                    self.isTurnInFlight = false
                    print("✅ [VC \(self.instanceID)] Reset instruction LLM done, waiting for audio playback to complete...")

                    // Wait for audio playback to actually finish
                    self.liveAudio.onPlaybackComplete { [weak self] in
                        Task { @MainActor in
                            guard let self else { return }
                            print("✅ [VC \(self.instanceID)] Audio playback complete, enabling tap now")

                            // Enable tap now that speech is actually complete
                            NotificationCenter.default.post(
                                name: .arCommand,
                                object: nil,
                                userInfo: [BusKey.arg: "enableTapAfterSpeech"]
                            )
                            print("📤 [VC \(self.instanceID)] Posted enableTapAfterSpeech - tap now enabled")

                            // Reset flag to allow future reset instructions
                            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                            self.isProcessingResetInstruction = false
                            self.state = .idle
                        }
                    }
                }
            },
            onError: { [weak self] err in
                Task { @MainActor in
                    guard let self else { return }
                    self.llmActive = false
                    self.isTurnInFlight = false
                    self.isProcessingResetInstruction = false
                    self.append("\n[error] \(err.localizedDescription)")
                    self.liveAudio.stop()
                    self.state = .idle
                }
            }
        )
    }

    func handlePostResetEncouragement() {
        print("✅ [VC \(instanceID)] Processing post-reset encouragement")
        print("   Current state: isTurnInFlight=\(isTurnInFlight), state=\(state)")

        let context = """
        Good! The child is ready to try again. Guide them through the safety steps:

        Say: "Great! Now let's practice the right way. If you see a gun, remember the 4 steps:
        1. STOP
        2. DON'T TOUCH
        3. RUN AWAY
        4. TELL AN ADULT

        Can you show me what you would do? Start with STOP."

        Be encouraging and enthusiastic. Have them practice each step.
        """

        Task { @MainActor in
            print("🧵 [VC \(self.instanceID)] Starting postReset task")

            // Stop any current conversation or audio
            LiveMicController.shared.stop()
            liveAudio.stop()

            guard beginTurn(kind: "postReset", prompt: context) else {
                print("⚠️ [VC \(self.instanceID)] beginTurn returned false, aborting")
                return
            }

            print("🎙 [VC \(self.instanceID)] Streaming postReset context to LLM")
            liveHandle = live.stream(userText: context, handlers: audioConversationHandlers())
        }
    }

    func injectContext(_ context: String) {
        Task { @MainActor in
            await live.sendText(context)
        }
    }
}
