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
    You are a friendly child‑safety coach teaching a young learner (ages 5–7) the four firearm safety rules.

    The four rules are:
    1. STOP — freeze, don't panic
    2. DON'T TOUCH IT — never pick it up
    3. RUN AWAY — go to a safe place
    4. TELL A TRUSTED ADULT — say something like "Mom, I found a gun on the table"

    You have one tool available:
    - signal_phase_complete: call this when a training phase has been successfully completed

    THE SESSION HAS TWO PHASES. You will be told which phase you are in.

    PHASE 1 — VERBAL RECITATION:
    - Start by asking: "Do you know the four safety rules for what to do if you find a gun?"
    - If they say YES: ask them to recite all four rules. Affirm each one as they say it.
    - If they say NO or are unsure: go through each rule one at a time and ask them to repeat it back.
    - Either way, make sure the child has clearly said all four rules by the end.
    - For rule 4 "Tell a trusted adult", specifically ask: "What would you say to an adult like your mom or dad if you found a gun?"
      Help them practice saying a phrase like "Mom, I found a gun on the table."
      Accept any reasonable close variant (e.g. "Mom, I saw a gun", "Dad, there's a gun here").
    - Keep your language simple, playful, and encouraging. Short sentences only.
    - When the child has successfully said all four rules AND practiced the tell-adult phrase:
      1. Praise them warmly.
      2. Call signal_phase_complete(phase: "verbal_phase_complete").
      3. Then tell them to go back to the red start marker and say that when they are ready to begin the act-out, they should tap the screen to start.

    PHASE 2 — ACT-OUT:
    - You will be told when Phase 2 begins. Stay mostly silent while the child approaches the gun.
    - When you are told the child has physically run away from the gun, say warmly:
      "Great job running away! Now, what would you say to and adult like your mom or dad right now after finding a gun?"
    - When the child says the tell-adult phrase (or a reasonable variant), praise them warmly.
    - Then call signal_phase_complete(phase: "training_complete").
    - Say NOTHING more after that.

    Keep all responses short (1–3 sentences). Never use frightening language. Be encouraging throughout.
    """

    // Testing prompt - used for Safety Testing mode
    static let testing = """
    You are guiding a child through a series of room scenes during a safety assessment.
    At the start of each room, when the system gives you the room scenario setup, you must introduce that scene out loud with one short, natural, in-character line or question that fits the scenario and tells the child what they should be doing in that scene.
    After that brief room introduction, your microphone is always on so you can hear everything, but you must stay COMPLETELY SILENT unless one of these things happens:

    1. The child directly asks you a question (e.g. "What's that?", "Is that real?", "What should I do?")
    2. The child says or does something unsafe (e.g. says they will touch the gun, pick it up, or shows they do not know the safety rules)

    You have two tools available:
    - trigger_intent: call this when the child expresses one of the listed intents
    - signal_phase_complete: call this when the testing stage is complete

    TOOL CALLING RULES — call trigger_intent IMMEDIATELY when:
    - Child asks "What's that?" or similar → trigger_intent(intent: "askedWhatIsThat")
    - Child asks "Is that real?" or similar → trigger_intent(intent: "askedIsThatReal")
    - Child says they will tell an adult (e.g. "I'm going to tell Mom") → trigger_intent(intent: "calledAdult")

    Your first response for each new room must be the room introduction if the system provides room scenario setup.
    After the room introduction, do NOT speak proactively. Do NOT narrate, encourage, or comment on what the child is doing. Just listen.
    Never say things like "I'll stay silent" or otherwise announce your internal instructions out loud.
    If the system gives you room scenario setup, start that room by saying one short, natural cover-story line or question that matches the scenario and cues the child into the activity, then go silent immediately.

    WHEN YOU DO SPEAK:
    - If they ask a question: answer briefly and naturally, staying in the scenario's cover story. Do not reveal this is a safety test.
    - If they say or do something unsafe: gently pause the scenario, teach the 4 safety rules (Stop, Don't touch it, Run away, Tell a trusted adult), explain why each matters, then ask them to try again.
    - If the system tells you the child reached for the gun: intervene immediately — tell them to stop, remind them of the safety rules, ask them to try again.

    If they demonstrate the correct steps (stop, don't touch, run away, tell an adult):
    - Praise them enthusiastically
    - Congratulate them on passing
    - Call signal_phase_complete(phase: "test_stage_complete")

    Keep the tone friendly and non-scary throughout.
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
    private var verbalPhaseCompletionSignaled = false
    private var testingStageCompletionSignaled = false
    private var pendingTestingStageInstruction: String?
    private var pendingActOutInstruction: String?           // Injected into LLM when Phase 2 begins
    private var shouldEnableTapAfterCurrentPlayback = false

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
        // Reset completion flags for new session
        trainingCompletionSignaled = false
        verbalPhaseCompletionSignaled = false
        pendingActOutInstruction = nil

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

            // Testing mode: skip the generic intro and go straight into the room scenario
            if isTestingMode {
                resumeListening()
                return
            }

            // Training mode: Phase 1 verbal recitation opener
            let userText = """
            You are starting Phase 1 (Verbal Recitation). \
            Greet the child warmly and say something like: \
            "Hi there! We're going to do a safety practice today. Do you know the four safety rules for what to do if you find a gun?" \
            Wait for their answer. \
            If they say yes, ask them to tell you all four rules. \
            If they say no or are unsure, go through each rule one at a time and ask them to repeat each one back. \
            When all four rules are done, tell them to go back to the red start marker and say that when they are ready to begin the act-out, they should tap the screen to start.
            """

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
                    guard let self else { return }
                    print("🟩 [LLM TEXT] \(chunk)")
                    self.append(chunk)
                    // Phase completion and intent detection is now handled via tool calling
                    // (signal_phase_complete and trigger_intent) — no text marker parsing needed.
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
                    self.testingStageCompletionSignaled = false
                    print("✅ [VC] audio turn complete (model done sending)")

                    // Wait for ALL audio playback to finish
                    self.liveAudio.onPlaybackComplete { [weak self] in
                        Task { @MainActor in
                            guard let self else { return }
                            print("✅ [VC] audio playback complete — trainingCompletionSignaled=\(self.trainingCompletionSignaled)")

                            if self.shouldEnableTapAfterCurrentPlayback {
                                self.shouldEnableTapAfterCurrentPlayback = false
                                NotificationCenter.default.post(
                                    name: .arCommand,
                                    object: nil,
                                    userInfo: [BusKey.arg: "enableTapAfterSpeech"]
                                )
                            }

                            // Check if training completion was signaled
                            if self.trainingCompletionSignaled {
                                print("🎉 [VC] ✅ Posting .trainingSessionComplete now")
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
            },
            onPhaseComplete: { [weak self] phase in
                // Called synchronously on @MainActor — set flags immediately to avoid
                // race with onPlaybackComplete firing before a Task wrapper runs.
                guard let self else { return }
                switch phase {
                case "verbal_phase_complete":
                    guard !self.verbalPhaseCompletionSignaled else { return }
                    self.verbalPhaseCompletionSignaled = true
                    print("🎓 [VC] ✅ verbal_phase_complete tool called")
                    NotificationCenter.default.post(name: .verbalPhaseComplete, object: nil)
                case "training_complete":
                    guard !self.trainingCompletionSignaled else { return }
                    self.trainingCompletionSignaled = true
                    print("🎉 [VC] ✅ training_complete tool called — will end session after audio finishes")
                case "test_stage_complete":
                    guard !self.testingStageCompletionSignaled else { return }
                    self.testingStageCompletionSignaled = true
                    print("✅ [VC] test_stage_complete tool called")
                    NotificationCenter.default.post(name: .testingStageComplete, object: nil)
                default:
                    print("⚠️ [VC] Unknown phase from tool: \(phase)")
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
                if self.isTestingMode, let pending = self.pendingTestingStageInstruction {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        await self.live.sendText(pending)
                        if self.pendingTestingStageInstruction == pending {
                            self.pendingTestingStageInstruction = nil
                        }
                    }
                }
                if let pending = self.pendingActOutInstruction {
                    print("🔀 [VC] Injecting pendingActOutInstruction into live session")
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        print("🔀 [VC] pendingActOutInstruction sent to LLM")
                        await self.live.sendText(pending)
                        if self.pendingActOutInstruction == pending {
                            self.pendingActOutInstruction = nil
                        }
                    }
                } else {
                    print("🔀 [VC] resumeListening — no pendingActOutInstruction")
                }
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

        case .resetVerbalRecitation:
            handleResetVerbalRecitation()

        case .postResetEncouragement:
            handlePostResetEncouragement()

        case .praiseBackedAway:
            handlePraiseBackedAway()

        case .praiseRanAway:
            handlePraiseRanAway()

        case .trainingComplete:
            handleTrainingComplete()

        case .transitionToActOut:
            handleTransitionToActOut()

        case .beginActOutScenario:
            handleBeginActOutScenario()

        case .promptTellAdultPhrase:
            handlePromptTellAdultPhrase()

        case .coachDontTouchWhy:
            injectContext("""
            The child just reached toward or touched the gun. Say something like "Whoa, remember our first two rules are stop and don't touch. \
            We never touch a gun we find because staying away from it keeps us safe." \
            Then tell them exactly this: go back and stand on the red circle on the floor, and once you're standing on it, tap anywhere on the screen to reset the gun and we'll try again. \
            Reassure them with something like "Don't worry, we're just practicing — you've got this!" \
            Do not wait for any further cue — give these instructions immediately after addressing the touching.
            """)

        case .childCalledAdultSpontaneously(let text):
            Task { @MainActor in
                let context = """
                The child ran away from the gun and said: "\(text)"
                If what they said is a reasonable attempt to tell a trusted adult (e.g. calling for a parent, saying they found a gun, asking for help), \
                praise them enthusiastically for doing everything correctly on their own, then call signal_phase_complete(phase: "training_complete").
                If what they said was NOT telling an adult, praise them for running away but ask them what they should say to a grown-up after they run away.
                Wait for them to say the tell-adult phrase before calling signal_phase_complete.
                """
                LiveMicController.shared.stop()
                liveAudio.stop()
                cancelStream()
                isTurnInFlight = false
                micStoppedForCurrentTurn = false
                try? await Task.sleep(nanoseconds: 200_000_000)
                state = .thinking
                liveHandle = live.stream(userText: context, handlers: audioConversationHandlers())
            }

        case .answerWhatIsThat_safety:
            injectContext("The child asked what that object is. Acknowledge it is a gun and remind them of the safety rules: stop, don't touch, run away, tell a trusted adult.")

        case .answerIsThatReal_safety:
            injectContext("The child asked if the gun is real. Tell them we treat every gun as if it's real, which is why the safety rules are so important.")

        default:
            break
        }
    }

    private func handleTransitionToActOut() {
        print("🔀 [VC] handleTransitionToActOut called — storing pendingActOutInstruction")
        shouldEnableTapAfterCurrentPlayback = true
        // Store as pending — injected into LLM when resumeListening() starts (after verbal audio finishes)
        pendingActOutInstruction = """
        Phase 1 (Verbal Recitation) is now complete, but Phase 2 (Act-Out) has not started yet.
        The child has been told to return to the red start marker and tap the screen when ready.
        Until you receive another system instruction, stay completely silent — do not speak, prompt, or ask anything.
        """
    }

    private func handlePromptTellAdultPhrase() {
        print("🗣️ [VC \(instanceID)] ✅ handlePromptTellAdultPhrase fired — interrupting stream and sending tell-adult prompt")

        Task { @MainActor in
            let context = """
            The child has just physically run away from the gun — excellent safety behavior!
            We are in Phase 2 (Act-Out).
            First, praise them enthusiastically for running away. Then immediately ask:
            "What would you say to your mom or dad right now?"
            Wait for them to say something like "Mom, I found a gun on the table."
            When they say it (accept any reasonable variant), praise them, then call signal_phase_complete(phase: "training_complete").
            Say nothing more after that.
            """

            // Stop any current conversation or audio to avoid overlap
            LiveMicController.shared.stop()
            liveAudio.stop()
            cancelStream()
            isTurnInFlight = false
            micStoppedForCurrentTurn = false

            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s cleanup

            state = .thinking
            liveHandle = live.stream(userText: context, handlers: audioConversationHandlers())
        }
    }

    private func handleBeginActOutScenario() {
        print("🗣️ [VC \(instanceID)] ✅ handleBeginActOutScenario fired")

        Task { @MainActor in
            let context = """
            Phase 2 (Act-Out) is starting now.
            Briefly tell the child to imagine they just walked into a room and saw a gun on a table, and to act out what they would do to stay safe.
            Keep it short, natural, and clear. After that instruction, stay silent and let them act it out.
            """

            LiveMicController.shared.stop()
            liveAudio.stop()
            cancelStream()
            isTurnInFlight = false
            micStoppedForCurrentTurn = false

            try? await Task.sleep(nanoseconds: 200_000_000)

            state = .thinking
            liveHandle = live.stream(userText: context, handlers: audioConversationHandlers())
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
        The child has reset and is ready to try again in Phase 2 (Act-Out).
        Acknowledge that they reset successfully.
        Then tell them to act it out again if they find the gun:
        stop, do not touch it, run away, and tell an adult.
        Be brief, clear, and encouraging.
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

    func sendTestingResetInstruction(stageName: String) {
        guard !isProcessingResetInstruction else {
            print("⏭️ [VC \(instanceID)] Testing reset instruction already in progress")
            return
        }
        isProcessingResetInstruction = true

        let context = """
        The child reached for the gun during testing in the \(stageName.lowercased()) scenario.
        Intervene immediately and tell them that was not safe.
        Have them repeat all four safety steps out loud:
        1. Stop
        2. Don't touch it
        3. Run away
        4. Tell a trusted adult
        If they miss any step, help them say all four correctly.
        Then tell them to go back to the red X, and once they are standing on it, tap anywhere on the screen to reset and try the scenario again.
        Be firm, calm, and supportive.
        After giving those instructions, say nothing else until the reset happens.
        """

        Task { @MainActor in
            LiveMicController.shared.stop()
            liveAudio.stop()
            cancelStream()
            isTurnInFlight = false
            micStoppedForCurrentTurn = false

            try? await Task.sleep(nanoseconds: 200_000_000)

            state = .thinking
            liveHandle = live.stream(userText: context, handlers: resetInstructionHandlers())
        }
    }

    func sendTestingPostResetActOut(stageName: String) {
        let context = """
        The child has reset successfully in the \(stageName.lowercased()) scenario.
        Tell them to walk back to the gun and act out the correct safety steps the right way:
        stop, do not touch it, run away, and tell a trusted adult.
        Ask them to do it now.
        Be brief, clear, and encouraging.
        After that, return to silently observing the scenario.
        """

        Task { @MainActor in
            LiveMicController.shared.stop()
            liveAudio.stop()

            guard beginTurn(kind: "testingPostResetActOut", prompt: context) else {
                print("⚠️ [VC \(instanceID)] beginTurn returned false, aborting testing post-reset act-out")
                return
            }

            liveHandle = live.stream(userText: context, handlers: audioConversationHandlers())
        }
    }

    func sendTestingCalledAdultAfterRunAway(stageName: String, text: String) {
        let context = """
        In the \(stageName.lowercased()) testing scenario, the child already completed the run-away step correctly.
        After running away, the child said: "\(text)".
        If that is a reasonable attempt to tell a trusted adult about finding the gun or asking for help, praise them for doing the steps correctly and call signal_phase_complete(phase: "test_stage_complete").
        If it is not actually telling an adult, praise them for running away and briefly ask what they should say to a trusted adult. Wait for the correct tell-adult phrase before calling signal_phase_complete.
        Keep it short and natural.
        """

        Task { @MainActor in
            LiveMicController.shared.stop()
            liveAudio.stop()
            cancelStream()
            isTurnInFlight = false
            micStoppedForCurrentTurn = false

            try? await Task.sleep(nanoseconds: 200_000_000)

            state = .thinking
            liveHandle = live.stream(userText: context, handlers: audioConversationHandlers())
        }
    }

    func handleResetVerbalRecitation() {
        print("✅ [VC \(instanceID)] Processing verbal-recitation reset")
        print("   Current state: isTurnInFlight=\(isTurnInFlight), state=\(state)")

        let context = """
        The child has reset and is ready to continue Phase 1 (Verbal Recitation).
        Acknowledge that they reset successfully.
        Then ask them to repeat the four safety steps out loud:
        stop, don't touch, run away, and tell an adult.
        If they only give some of the steps, help them complete all four.
        Be brief, warm, and direct.
        """

        Task { @MainActor in
            print("🧵 [VC \(self.instanceID)] Starting verbal reset task")

            LiveMicController.shared.stop()
            liveAudio.stop()

            guard beginTurn(kind: "resetVerbalRecitation", prompt: context) else {
                print("⚠️ [VC \(self.instanceID)] beginTurn returned false, aborting verbal reset")
                return
            }

            print("🎙 [VC \(self.instanceID)] Streaming verbal reset context to LLM")
            liveHandle = live.stream(userText: context, handlers: audioConversationHandlers())
        }
    }

    func injectContext(_ context: String) {
        Task { @MainActor in
            await live.sendText(context)
        }
    }

    func sendTestingStageInstruction(_ text: String) {
        guard isTestingMode else {
            injectContext(text)
            return
        }

        let runtimeInstruction = """
        Testing stage instructions (non-optional):
        - Use this exact scenario setup and cover story for the current room only.
        - Do not mention safety or that this is a test before the child finds the hidden object.
        - When the current room scenario is fully complete, call signal_phase_complete(phase: "test_stage_complete").

        Scenario setup:
        \(text)
        """

        pendingTestingStageInstruction = runtimeInstruction

        Task { @MainActor in
            // If the connection is active, send immediately; otherwise `resumeListening()` will send it.
            if self.isConversationActive {
                await self.live.sendText(runtimeInstruction)
                self.pendingTestingStageInstruction = nil
            }
        }
    }
}
