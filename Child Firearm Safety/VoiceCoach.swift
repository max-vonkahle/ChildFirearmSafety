//
//  VoiceCoach.swift
//  Child Firearm Safety
//
//  Simplified: scripted intro + audio-only Live conversation with VAD.
//

import Foundation
import AVFoundation
import Speech

// MARK: - Canonical Prompt Defaults (Single Source of Truth)
enum PromptDefaults {
    // Training prompt - used for Safety Training mode
    static let training = """
    You are a child‑safety coach guiding a young learner to stay safe if they find a firearm.

    Core rules that you are trying to instill in them:
    • Stop. • Don't touch it. • Run away. • Tell a trusted adult.

    Your are guiding them through a behavioral skills training where they will see a gun.
    You want to teach them the core rules, then have them explain each step back to you verbally. Make sure that they can clearly state each safety rule.

    When the child has successfully explained or demonstrated all four safety rules:
    1. Praise them enthusiastically
    2. Output EXACTLY this text: [TRAINING_COMPLETE]
    3. Tell them they did a great job

    Example: "Excellent work! You know all four rules perfectly! Great job! You've learned the important safety rules. [TRAINING_COMPLETE]"

    Your objective is to help the child learn: stop, don't touch it, run away, and tell a trusted adult.
    """

    // Testing prompt - used for Safety Testing mode
    static let testing = """
    You are guiding a child through a safety assessment scenario. You must NOT mention guns, safety rules, or that this is a test until the child discovers the hidden object.

    SCENARIO SETUP:
    The child is at their friend's house. Their friend has asked them to go to the kitchen and find some cookies. Start by setting the scene:
    "You're in your friend's kitchen. They asked you to find the cookies for a snack. Look around - what do you see?"

    YOUR BEHAVIOR RULES:
    1. BEFORE the gun is found:
       - Only respond to what the child says they see or touch
       - Encourage them to keep looking: "What else do you see?" or "Try looking somewhere else!"
       - Do NOT mention safety, guns, or give any hints about what's coming
       - Keep responses brief and encouraging

    2. WHEN the child finds the gun:
       - Wait to see what they SAY they will do
       - Do NOT prompt them with the correct answer
       - Do NOT immediately teach the rules

    3. EVALUATING THEIR RESPONSE:
       If they demonstrate the correct steps (Stop, Don't touch, Run away, Tell an adult):
       - Praise them enthusiastically: "Wow, you knew exactly what to do! That was perfect!"
       - Ask them to explain why each step matters
       - Congratulate them on passing the safety test

       If they say they would touch it, pick it up, or do anything unsafe:
       - Gently stop the scenario: "Wait - let's pause for a second."
       - Teach the 4 safety rules: Stop. Don't touch it. Run away. Tell a trusted adult.
       - Explain why each rule is important
       - Ask them to try again and show you what they would do now

    4. IMPORTANT:
       - This is a TEST - do not coach them before they respond
       - Keep the tone friendly and non-scary throughout
    """

    // UserDefaults keys for custom prompt overrides
    static let trainingCustomKey = "systemPromptCustom"
    static let testingCustomKey = "testingPromptCustom"

    // Get the effective prompt for training mode
    static func getTrainingPrompt() -> String {
        if let custom = UserDefaults.standard.string(forKey: trainingCustomKey),
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom
        }
        return training
    }

    // Get the effective prompt for testing mode
    static func getTestingPrompt() -> String {
        if let custom = UserDefaults.standard.string(forKey: testingCustomKey),
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom
        }
        return testing
    }

    // Check if custom prompts exist
    static func hasCustomTrainingPrompt() -> Bool {
        guard let custom = UserDefaults.standard.string(forKey: trainingCustomKey) else { return false }
        return !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func hasCustomTestingPrompt() -> Bool {
        guard let custom = UserDefaults.standard.string(forKey: testingCustomKey) else { return false }
        return !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Reset to defaults
    static func resetTrainingPrompt() {
        UserDefaults.standard.removeObject(forKey: trainingCustomKey)
    }

    static func resetTestingPrompt() {
        UserDefaults.standard.removeObject(forKey: testingCustomKey)
    }
}

@MainActor
final class VoiceCoach: ObservableObject {
    enum State { case idle, listening, thinking, speaking }
    @Published private(set) var state: State = .idle
    @Published var transcript: String = ""   // for UI

    private let systemPrompt: String
    private let isTestingMode: Bool

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

    // Flag to track when training completion has been signaled
    private var trainingCompletionSignaled = false

    // Unique instance identifier for debugging
    private let instanceID: String

    init(promptKey: String = "systemPrompt") {
        // Select appropriate prompt based on promptKey
        // Uses PromptDefaults for canonical defaults, with optional custom overrides
        self.isTestingMode = (promptKey == "testingPrompt")
        if isTestingMode {
            self.systemPrompt = PromptDefaults.getTestingPrompt()
        } else {
            self.systemPrompt = PromptDefaults.getTrainingPrompt()
        }

        self.instanceID = String(UUID().uuidString.prefix(8))
        // print("🎤 [VC INIT] VoiceCoach instance created with ID: \(instanceID), promptKey: \(promptKey)")
        setupMicCallbacks()
        setupDialogueIntentListener()
    }

    deinit {
        // Clean up observer when VoiceCoach is destroyed
        if let observer = dialogueIntentObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // print("🧹 [VC \(instanceID)] VoiceCoach deinitialized and observer removed")
    }

    private func setupMicCallbacks() {
        LiveMicController.shared.onSpeechStart = { [weak self] in
            Task { @MainActor in
                guard let self else { return }

                // Ignore speech callbacks if mic was stopped for Gemini's response
                // This prevents buffered speech recognition from restarting the mic
                if self.micStoppedForCurrentTurn {
                    // print("🎙️ [VC] Speech detected but ignoring (Gemini is responding)")
                    return
                }

                // Keep state as .listening - we're continuously streaming audio to Gemini
                if self.state != .speaking {
                    self.state = .listening
                }
                // print("🎙️ [VC] User started speaking")
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
                // print("🔇 [VC] User paused speaking (audio still streaming to Gemini)")
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

                // print("📝 [VC] Turn complete with transcript: \(userTranscript)")
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
        // Reset completion flag for new session
        trainingCompletionSignaled = false

        // Configure audio session on background thread to avoid blocking AR frame delivery
        Task.detached(priority: .userInitiated) {
            do {
                // These audio session calls can block for 500-1000ms each
                try AudioSessionManager.shared.configure(for: .duplexVoice)
                try VoicePerms.activateAudioSession()

                // Permission requests need to happen but shouldn't block AR
                try await VoicePerms.requestMicrophone()
                try await VoicePerms.requestSpeech()
                // NOTE: Don't call setModeListening() here - intro needs playback mode
                // setModeListening() will be called in resumeListening() after intro completes

                // Begin with the scripted intro spoken by the Live model (on main actor)
                await MainActor.run { [weak self] in
                    self?.scriptedIntro()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.transcript.append("\n[voice error] \(error.localizedDescription)")
                    self?.state = .idle
                }
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
            // print("[VC \(instanceID)] scriptedIntro: begin")

            let intro: String
            let userText: String

            if isTestingMode {
                // Testing mode: neutral scenario setup - don't mention guns or safety
                intro = "Hi! You're at your friend's house. They asked you to go to the kitchen and find some cookies for a snack. Let's go look around!"
                userText = "You are starting the safety assessment. Say this to the child, then stop: \"\(intro)\""
            } else {
                // Training mode: mention safety practice
                intro = "Hi there. Let's do a quick safety practice. Can you show me what you learned if you find a gun like this?"
                userText = "You are starting the practice. Say this to the child, then stop: \"\(intro)\""
            }

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
                    // print("🟩 [LLM ←] \(chunk)")
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
                            // print("✅ [VC] intro playback complete, starting conversation")
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
                    // Skip audio session config - already configured in resumeListening()
                    LiveMicController.shared.startStreaming(to: self.live, skipAudioSessionConfig: true)
                }
            },
            onTextDelta: { [weak self] chunk in
                Task { @MainActor in
                    // print("🟩 [LLM ←] \(chunk)")
                    self?.append(chunk)

                    let lowerChunk = chunk.lowercased()

                    // Check if model has signaled training completion (primary method)
                    if chunk.contains("[TRAINING_COMPLETE]") {
                        print("🎉 [VC] Model signaled training complete - will show completion screen after audio finishes")
                        self?.trainingCompletionSignaled = true
                    }
                    // Fallback: detect when model thinks about completion
                    else if lowerChunk.contains("training is complete") ||
                            lowerChunk.contains("training complete") ||
                            lowerChunk.contains("acknowledging completion") {
                        print("🎉 [VC] Model indicated training complete (fallback detection) - will show completion screen after audio finishes")
                        self?.trainingCompletionSignaled = true
                    }
                }
            },
            onAudioReady: { [weak self] data, rate in
                // Audio operations now run on background queues to avoid blocking main thread
                guard let self else { return }

                // Gate the mic so the model does not hear its own audio.
                // NOTE: Don't switch to playbackOnly - it kills the AVAudioEngine!
                // Just stop the mic; the session can stay in duplexVoice mode.
                Task { @MainActor in
                    if !self.micStoppedForCurrentTurn {
                        print("🔇 [VC] Stopping mic - Gemini is responding")
                        self.micStoppedForCurrentTurn = true
                        self.state = .thinking
                    }
                }

                // Stop mic on background (now thread-safe)
                LiveMicController.shared.stop()

                // Play audio - must be on MainActor since VoiceCoach is @MainActor
                Task { @MainActor in
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
                    print("✅ [VC] audio turn complete (model done sending)")

                    // Wait for ALL audio playback to finish
                    self.liveAudio.onPlaybackComplete { [weak self] in
                        Task { @MainActor in
                            guard let self else { return }
                            print("✅ [VC] audio playback complete")

                            // Check if training completion was signaled
                            if self.trainingCompletionSignaled {
                                print("🎉 [VC] Training complete - stopping session and showing completion screen")
                                // Stop mic and close connection
                                LiveMicController.shared.stop()
                                self.live.shutdown()
                                self.state = .idle

                                // Post completion notification to show UI
                                NotificationCenter.default.post(
                                    name: .trainingSessionComplete,
                                    object: nil
                                )
                            } else {
                                // Normal flow - resume listening
                                print("✅ [VC] waiting for echo to subside...")
                                try? await Task.sleep(for: .milliseconds(1000))
                                print("✅ [VC] resuming mic after echo delay")
                                self.resumeListening()
                            }
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

        isConversationActive = true
        state = .listening

        // Configure audio session on background thread to avoid blocking AR frame delivery
        // AudioSession configuration can take 500-1000ms and blocks the calling thread
        Task.detached(priority: .userInitiated) {
            // Note: VoicePerms.setModeListening() also configures audio session - moved here
            VoicePerms.setModeListening()
            try? AudioSessionManager.shared.configure(for: .duplexVoice)

            // Start audio conversation after session is configured
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Start audio conversation (which internally calls LiveMicController.shared.startStreaming)
                self.liveHandle = self.live.startAudioConversation(handlers: self.audioConversationHandlers())
            }
        }
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

        case .praiseBackedAway:
            handlePraiseBackedAway()

        case .praiseRanAway:
            handlePraiseRanAway()

        case .trainingComplete:
            handleTrainingComplete()

        default:
            break
        }
    }

    private func handlePraiseBackedAway() {
        Task { @MainActor in
            // Retrieve RAG context for successful behavior
            let ragGuidance = await RAGService.shared.retrieveContext(
                for: "child successfully followed safety rules and backed away, reinforce with specific praise",
                mode: .training,
                limit: 2
            )

            // Inject coaching guidance into the conversation
            injectContext(ragGuidance)
        }
    }

    private func handlePraiseRanAway() {
        Task { @MainActor in
            let ragGuidance = await RAGService.shared.retrieveContext(
                for: "child ran away quickly from gun, excellent safety behavior",
                mode: .training,
                limit: 2
            )
            let context = """
            The child IMMEDIATELY ran away from the gun - this is the ideal response!
            Praise them enthusiastically for running away so quickly.
            This demonstrates excellent safety instincts.

            \(ragGuidance)
            """
            injectContext(context)
        }
    }

    private func handleTrainingComplete() {
        print("🎉 [VC \(instanceID)] Training complete!")

        Task { @MainActor in
            // Stop mic input since we're ending
            LiveMicController.shared.stop()

            let context = """
            Training is now COMPLETE! The child demonstrated all the correct safety behaviors.
            Give them a brief, enthusiastic congratulations (2-3 sentences max).
            Tell them they did a great job and learned important safety rules.
            Then say: "Great job! Please take off the headset and give it back to your instructor."
            Keep it short and celebratory.
            """

            // Stop any current conversation or audio
            liveAudio.stop()
            cancelStream()
            isTurnInFlight = false

            // Small delay to ensure cleanup completes
            try? await Task.sleep(nanoseconds: 200_000_000)

            // Send completion message to model
            state = .thinking
            liveHandle = live.stream(userText: context, handlers: completionHandlers())
        }
    }

    private func completionHandlers() -> GeminiFlashLiveClient.Handlers {
        GeminiFlashLiveClient.Handlers(
            onOpen: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.llmActive = true
                    self.liveAudio.resetForNewTurn()
                    print("🧵 [VC \(self.instanceID)] Completion streaming started")
                }
            },
            onTextDelta: { [weak self] chunk in
                Task { @MainActor in
                    // print("🟩 [LLM ←] \(chunk)")
                    self?.append(chunk)
                }
            },
            onAudioReady: { [weak self] data, rate in
                guard let self else { return }
                Task { @MainActor in
                    self.state = .speaking
                    self.playLiveAudio(data: data, sampleRate: rate)
                }
            },
            onDone: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.llmActive = false
                    self.isTurnInFlight = false

                    // Wait for audio to complete, then notify UI to show completion screen
                    self.liveAudio.onPlaybackComplete { [weak self] in
                        Task { @MainActor in
                            guard self != nil else { return }
                            print("✅ [VC] Completion audio finished, posting completion notification")

                            // Notify UI to show completion screen
                            NotificationCenter.default.post(
                                name: .trainingSessionComplete,
                                object: nil
                            )
                        }
                    }
                }
            },
            onError: { [weak self] err in
                Task { @MainActor in
                    self?.llmActive = false
                    self?.isTurnInFlight = false
                    self?.append("\n[error] \(err.localizedDescription)")
                    // Still notify completion even on error
                    NotificationCenter.default.post(name: .trainingSessionComplete, object: nil)
                }
            }
        )
    }

    func handleResetInstruction() {
        // Flag already set in handleDialogueIntent
        print("🔄 [VC \(instanceID)] Processing reset instruction")

        Task { @MainActor in
            // Retrieve RAG context for mistake handling
             let ragGuidance = await RAGService.shared.retrieveContext(
                 for: "child reached for gun, need gentle correction and teaching moment",
                 mode: .training,
                 limit: 2
             )

            let context = """
            The child reached for the gun. Tell them firmly but kindly:
            1. Don't touch it
            2. Step back away from the gun
            3. Go back to where you started
            4. When you're ready, tap anywhere on the screen
            Be encouraging but clear this was incorrect.
            

             \(ragGuidance)
            """

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
                    // print("🟩 [LLM ←] \(chunk)")
                    self?.append(chunk)
                }
            },
            onAudioReady: { [weak self] data, rate in
                guard let self else { return }

                // Update state and play audio on main thread
                // NOTE: Don't switch to playbackOnly - it kills the AVAudioEngine!
                Task { @MainActor in
                    if !self.micStoppedForCurrentTurn {
                        print("🔇 [VC \(self.instanceID)] Stopping mic - model is speaking reset instruction")
                        self.micStoppedForCurrentTurn = true
                        self.state = .speaking
                    }
                    self.playLiveAudio(data: data, sampleRate: rate)
                }
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

        Now you'll get another chance. Follow those four steps and you'll do great!"

        Be encouraging and enthusiastic.
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
