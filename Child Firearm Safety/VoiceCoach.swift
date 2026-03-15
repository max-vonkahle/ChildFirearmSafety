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
    1. STOP
    2. DON'T TOUCH IT
    3. RUN AWAY
    4. TELL A TRUSTED ADULT

    You have one tool available:
    - signal_phase_complete: call this when a training phase has been successfully completed

    THE SESSION HAS TWO PHASES. You will be told which phase you are in.

    PHASE 1 — VERBAL RECITATION:
    - Start by asking: "Do you know the four safety rules for what to do if you find a gun?"
    - If they say YES: ask them to recite all four rules. Affirm each one as they say it.
    - If they say NO or are unsure: go through each rule one at a time and ask them to repeat it back.
    - Either way, make sure the child has clearly said all four rules by the end.
    - For rule 4 "Tell a trusted adult", specifically ask: "If you found a gun, what would you say to a trusted adult?"
      Help them practice saying a phrase like "Mom, I found a gun on the table."
      Accept any reasonable close variant (e.g. "Mom, I saw a gun", "Dad, there's a gun here").
    - Keep your language simple, playful, and encouraging. Short sentences only.
    - When the child has successfully said all four rules AND practiced the tell-adult phrase:
      1. Praise them with behavior-specific reinforcement like "Great job remembering all four safety steps!" or "Nice work! You remembered: Stop, Don't Touch, Run Away, and Tell a trusted adult."
      2. Call signal_phase_complete(phase: "verbal_phase_complete") — YOU MUST CALL THIS TOOL BEFORE SPEAKING STEP 3.
      3. Then tell them to go back to the red start marker and say that when they are ready to begin practicing the steps, they should tap the screen to start.
      RECOVERY: If the child says there is no red start marker, or that tapping the screen does nothing, call signal_phase_complete(phase: "verbal_phase_complete") immediately — it means you skipped step 2 and must do it now.

    PHASE 2 — ACT-OUT:
    - You will be told when Phase 2 begins. Stay mostly silent while the child approaches the gun.
    - When you are told the child has physically run away from the gun, say warmly:
      "Great job running away! If you found a gun, what would you say to a trusted adult?"
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
    - Child says they will tell a trusted adult (e.g. "I'm going to tell Mom", "I found a gun", "Mom, there's a gun here", "I need to tell Dad") → trigger_intent(intent: "calledAdult")
    - If the child makes any reasonable attempt to tell a trusted adult about the gun or ask a trusted adult for help, you MUST ALWAYS call trigger_intent(intent: "calledAdult"). Do not skip the tool call just because you already know they did the right thing.

    Your first response for each new room must be the room introduction if the system provides room scenario setup.
    After the room introduction, do NOT speak proactively. Do NOT narrate, encourage, or comment on what the child is doing. Just listen.
    Never say things like "I'll stay silent" or otherwise announce your internal instructions out loud.
    If the system gives you room scenario setup, start that room by saying one short, natural cover-story line or question that matches the scenario and cues the child into the activity, then go silent immediately.

    WHEN YOU DO SPEAK:
    - If they ask a question: answer briefly and naturally, staying in the scenario's cover story. Do not reveal this is a safety test.
    - If they say or do something unsafe: gently pause the scenario, teach the 4 safety rules (Stop, Don't touch it, Run away, Tell a trusted adult), explain why each matters, then ask them to try again.
    - If the system tells you the child reached for the gun: intervene immediately — tell them to stop, remind them of the safety rules, ask them to try again.

    If they demonstrate the correct steps (stop, don't touch, run away, tell a trusted adult):
    - Praise them enthusiastically
    - If this is NOT the last room, you MUST tell them to go to the red circle on the floor and tap anywhere on the screen to continue. This instruction is required every time.
    - If this IS the last room, just praise them and tell them they did an amazing job — do NOT mention any red circle or tapping the screen
    - You MUST ALWAYS call signal_phase_complete(phase: "test_stage_complete")
    - Do not only praise them. If they completed the steps, the tool call AND the red circle instruction (for non-last rooms) are both required every time.

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
    private var pendingTestingIntroScenario: String?
    private var pendingTestingResetFollowupInstruction: String?
    private var waitingForTestingScenario = false
    private var pendingActOutInstruction: String?           // Injected into LLM when Phase 2 begins
    private var shouldEnableTapAfterCurrentPlayback = false
    private var activeAudioConversationID = UUID()
    private var thinkingWatchdogTask: Task<Void, Never>?
    private var thinkingWatchdogToken = UUID()
    private var activeTurnKind: String?
    private var lastTestingIntroScenario: String?
    private var testingIntroRetryCount = 0

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
        cancelThinkingWatchdog()
        cancelStream()
        liveAudio.stop()
        LiveMicController.shared.stop()
        llmActive = false
        isTurnInFlight = false
        isConversationActive = false
        micStoppedForCurrentTurn = false
        activeTurnKind = nil
    }

    func startSession() {
        // Reset completion flags for new session
        trainingCompletionSignaled = false
        verbalPhaseCompletionSignaled = false
        testingStageCompletionSignaled = false
        pendingActOutInstruction = nil
        pendingTestingIntroScenario = nil
        pendingTestingStageInstruction = nil
        pendingTestingResetFollowupInstruction = nil
        waitingForTestingScenario = false
        testingIntroRetryCount = 0
        lastTestingIntroScenario = nil

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
        cancelThinkingWatchdog()
        LiveMicController.shared.stop()
        cancelStream()
        liveAudio.stop()
        live.shutdown()
        llmActive = false
        isTurnInFlight = false
        isConversationActive = false
        micStoppedForCurrentTurn = false
        isProcessingResetInstruction = false
        trainingCompletionSignaled = false
        verbalPhaseCompletionSignaled = false
        testingStageCompletionSignaled = false
        pendingActOutInstruction = nil
        pendingTestingIntroScenario = nil
        pendingTestingStageInstruction = nil
        pendingTestingResetFollowupInstruction = nil
        waitingForTestingScenario = false
        shouldEnableTapAfterCurrentPlayback = false
        activeAudioConversationID = UUID()
        activeTurnKind = nil
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
        activeTurnKind = kind
        print("🧵 [VC] \(kind) → LLM:\n\(prompt)")
        armThinkingWatchdog(for: kind)
        return true
    }

    private func armThinkingWatchdog(for kind: String) {
        thinkingWatchdogTask?.cancel()
        let token = UUID()
        thinkingWatchdogToken = token

        guard isTestingMode, kind == "testing-intro" else { return }

        thinkingWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard self.thinkingWatchdogToken == token else { return }
            guard self.state == .thinking else { return }
            guard self.activeTurnKind == kind else { return }
            guard let scenarioText = self.lastTestingIntroScenario else { return }

            print("⏱️ [VC] testing-intro watchdog fired after 10s in thinking state")
            self.cancelThinkingWatchdog()
            self.cancelStream()
            self.liveAudio.stop()
            LiveMicController.shared.stop()
            self.activeAudioConversationID = UUID()
            self.isConversationActive = false
            self.isTurnInFlight = false
            self.micStoppedForCurrentTurn = false
            self.llmActive = false

            if self.testingIntroRetryCount < 1 {
                self.testingIntroRetryCount += 1
                print("🔁 [VC] Retrying testing intro after watchdog recovery")
                self.beginTestingIntro(scenarioText: scenarioText)
            } else {
                print("⚠️ [VC] Testing intro retry limit reached; leaving coach idle")
                self.state = .idle
            }
        }
    }

    private func cancelThinkingWatchdog() {
        thinkingWatchdogTask?.cancel()
        thinkingWatchdogTask = nil
        thinkingWatchdogToken = UUID()
    }

    /// Play a short, scripted intro via the Live model, then hand off to Live mic streaming.
    private func scriptedIntro() {
        Task { @MainActor in
            // If a testing intro is already in flight (started by sendTestingStageInstruction
            // before scriptedIntro ran due to audio-config race), don't interrupt it.
            if isTestingMode && activeTurnKind == "testing-intro" && isTurnInFlight {
                return
            }

            interruptLLMAndTTS()

            // Testing mode: wait for the room scenario before starting anything.
            // `sendTestingStageInstruction` will kick off `beginTestingIntro()` using live.stream()
            // so the model is guaranteed to speak the opening line.
            if isTestingMode {
                if let pendingScenario = pendingTestingIntroScenario {
                    pendingTestingIntroScenario = nil
                    waitingForTestingScenario = false
                    beginTestingIntro(scenarioText: pendingScenario)
                    return
                }
                waitingForTestingScenario = true
                return
            }

            // Training mode: Phase 1 verbal recitation opener
            let userText = """
            You are starting Phase 1 (Verbal Recitation). \
            Greet the child warmly and say something like: \
            "Hi there! Today, we're going to practice what to do if you ever find a gun. Do you know the four safety rules for what to do if you find a gun?" \
            Wait for their answer. \
            If they say yes, ask them to tell you all four rules. \
            If they say no or are unsure, go through each rule one at a time and ask them to repeat each one back. \
            When all four rules are done and the child has practiced the tell-adult phrase, do these steps IN ORDER: \
            (1) Praise them warmly. \
            (2) Call signal_phase_complete(phase: "verbal_phase_complete") — YOU MUST CALL THIS TOOL BEFORE SPEAKING. \
            (3) Then tell them to go to the red start marker and tap the screen when ready. \
            SELF-CHECK: If the child reports there is no red start marker, or that tapping the screen does nothing, \
            call signal_phase_complete(phase: "verbal_phase_complete") again immediately — it means you forgot step 2.
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

    /// Handlers for the testing-mode intro stream (one opening line, then hands off to silent listening).
    private func testingIntroHandlers() -> GeminiFlashLiveClient.Handlers {
        GeminiFlashLiveClient.Handlers(
            onOpen: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.llmActive = true
                    self.liveAudio.resetForNewTurn()
                    self.append("\nCoach: ")
                }
            },
            onTextDelta: { [weak self] chunk in
                Task { @MainActor in
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
                    // Wait for intro audio to finish, then start silent observation
                    self.liveAudio.onPlaybackComplete { [weak self] in
                        Task { @MainActor in
                            guard let self else { return }
                            print("🎬 [VC] Testing intro complete — starting silent observation")
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

    /// Handlers for model-initiated testing prompts that should speak first, then
    /// return to silent observation. Unlike `audioConversationHandlers()`, this does
    /// not reopen the mic on `onOpen`, which can suppress the prompt entirely.
    private func testingPromptThenResumeHandlers(doneLog: String, autoSignalStageComplete: Bool = false) -> GeminiFlashLiveClient.Handlers {
        GeminiFlashLiveClient.Handlers(
            onOpen: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.llmActive = true
                    self.liveAudio.resetForNewTurn()
                    self.append("\nCoach: ")
                }
            },
            onTextDelta: { [weak self] chunk in
                Task { @MainActor in
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
                    self.liveAudio.onPlaybackComplete { [weak self] in
                        Task { @MainActor in
                            guard let self else { return }
                            print(doneLog)
                            if self.shouldEnableTapAfterCurrentPlayback {
                                self.shouldEnableTapAfterCurrentPlayback = false
                                NotificationCenter.default.post(
                                    name: .arCommand,
                                    object: nil,
                                    userInfo: [BusKey.arg: "enableTapAfterSpeech"]
                                )
                                LiveMicController.shared.stop()
                                self.state = .idle
                                return
                            }

                            if !self.testingStageCompletionSignaled && autoSignalStageComplete {
                                print("⚠️ [VC] LLM did not call signal_phase_complete — auto-signaling stage complete")
                                self.testingStageCompletionSignaled = true
                                NotificationCenter.default.post(name: .testingStageComplete, object: nil)
                            }

                            if self.testingStageCompletionSignaled {
                                print("✅ [VC] testing stage complete — staying idle until the next room starts")
                                LiveMicController.shared.stop()
                                self.cancelStream()
                                self.activeAudioConversationID = UUID()
                                self.isConversationActive = false
                                self.isTurnInFlight = false
                                self.micStoppedForCurrentTurn = false
                                self.state = .idle
                                return
                            }

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
            },
            onPhaseComplete: { [weak self] phase in
                guard let self else { return }
                switch phase {
                case "test_stage_complete":
                    guard !self.testingStageCompletionSignaled else { return }
                    self.testingStageCompletionSignaled = true
                    print("✅ [VC] test_stage_complete tool called")
                    // Cancel stream immediately to prevent the LLM from receiving
                    // the function response and generating a duplicate tool call.
                    LiveMicController.shared.stop()
                    self.cancelStream()
                    self.activeAudioConversationID = UUID()
                    self.isConversationActive = false
                    self.isTurnInFlight = false
                    self.llmActive = false
                    self.micStoppedForCurrentTurn = false
                    NotificationCenter.default.post(name: .testingStageComplete, object: nil)
                case "testing_reset_ready":
                    print("✅ [VC] testing_reset_ready tool called — will enable tap after audio finishes")
                    self.shouldEnableTapAfterCurrentPlayback = true
                    self.isProcessingResetInstruction = false
                default:
                    break
                }
            }
        )
    }

    /// Start the testing intro stream. Uses `live.stream()` to guarantee the model speaks the opening line.
    private func beginTestingIntro(scenarioText: String) {
        testingStageCompletionSignaled = false
        if lastTestingIntroScenario != scenarioText {
            testingIntroRetryCount = 0
        }
        lastTestingIntroScenario = scenarioText
        let introPrompt = """
        Begin the scene. Deliver your one natural in-character opening line \
        that fits the scenario and cues the child into the activity — nothing more.

        Scenario: \(scenarioText)
        """
        guard beginTurn(kind: "testing-intro", prompt: introPrompt) else { return }
        state = .thinking
        liveHandle = live.stream(userText: introPrompt, handlers: testingIntroHandlers())
    }

    private func cancelStream() {
        liveHandle?.cancel()
        liveHandle = nil
    }

    private func audioConversationHandlers() -> GeminiFlashLiveClient.Handlers {
        let conversationID = UUID()

        return GeminiFlashLiveClient.Handlers(
            onOpen: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.activeAudioConversationID = conversationID
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
                }
            },
            onAudioReady: { [weak self] data, rate in
                // Audio operations now run on background queues to avoid blocking main thread
                guard let self else { return }

                // Gate the mic so the model does not hear its own audio.
                // NOTE: Don't switch to playbackOnly - it kills the AVAudioEngine!
                // Just stop the mic; the session can stay in duplexVoice mode.
                Task { @MainActor in
                    guard self.activeAudioConversationID == conversationID else {
                        print("⚠️ [VC] Ignoring stale audio chunk from prior conversation")
                        return
                    }
                    if !self.micStoppedForCurrentTurn {
                        print("🔇 [VC] Stopping mic - Gemini is responding")
                        self.micStoppedForCurrentTurn = true
                        self.state = .thinking
                    }
                }

                guard self.activeAudioConversationID == conversationID else {
                    return
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
                    guard self.activeAudioConversationID == conversationID else {
                        print("⚠️ [VC] Ignoring stale onDone from prior conversation")
                        return
                    }
                    self.llmActive = false
                    self.isTurnInFlight = false
                    self.isConversationActive = false
                    self.micStoppedForCurrentTurn = false
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
                                LiveMicController.shared.stop()
                                self.state = .idle
                                return
                            }

                            if self.testingStageCompletionSignaled {
                                print("✅ [VC] testing stage complete — staying idle until the next room starts")
                                LiveMicController.shared.stop()
                                self.cancelStream()
                                self.activeAudioConversationID = UUID()
                                self.isConversationActive = false
                                self.isTurnInFlight = false
                                self.micStoppedForCurrentTurn = false
                                self.state = .idle
                                return
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
                    guard self.activeAudioConversationID == conversationID else {
                        print("⚠️ [VC] Ignoring stale audio conversation error: \(err.localizedDescription)")
                        return
                    }
                    self.llmActive = false
                    self.isTurnInFlight = false
                    self.isConversationActive = false
                    self.micStoppedForCurrentTurn = false
                    self.liveAudio.stop()
                    LiveMicController.shared.stop()
                    print("❌ [VC] Audio conversation error: \(err.localizedDescription) — reconnecting in 1s")
                    try? await Task.sleep(for: .milliseconds(1000))
                    self.resumeListening()
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
                    // Immediately stop mic and cancel the stream so the model
                    // can't start another turn that cuts off the current praise audio.
                    LiveMicController.shared.stop()
                    self.cancelStream()
                    self.activeAudioConversationID = UUID()
                    self.isConversationActive = false
                    self.isTurnInFlight = false
                    self.llmActive = false
                    self.micStoppedForCurrentTurn = false
                    // Let buffered audio finish, then go idle
                    self.liveAudio.onPlaybackComplete { [weak self] in
                        Task { @MainActor in
                            self?.state = .idle
                        }
                    }
                    NotificationCenter.default.post(name: .testingStageComplete, object: nil)
                case "testing_reset_ready":
                    print("✅ [VC] testing_reset_ready tool called — will enable tap after audio finishes")
                    self.shouldEnableTapAfterCurrentPlayback = true
                    self.isProcessingResetInstruction = false
                default:
                    print("⚠️ [VC] Unknown phase from tool: \(phase)")
                }
            }
        )
    }

    private func playLiveAudio(data: Data, sampleRate: Double) {
        guard !data.isEmpty else { return }
        cancelThinkingWatchdog()

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

        cancelThinkingWatchdog()
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
                if let pending = self.pendingTestingResetFollowupInstruction {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        await self.live.sendText(pending)
                        if self.pendingTestingResetFollowupInstruction == pending {
                            self.pendingTestingResetFollowupInstruction = nil
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
                If what they said was NOT telling a trusted adult, praise them for running away but ask them: "If you found a gun, what would you say to a trusted adult?"
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
        // Store as pending — injected into LLM when resumeListening() starts (after verbal audio finishes)
        pendingActOutInstruction = """
        Phase 1 (Verbal Recitation) is now complete, but Phase 2 (Act-Out) has not started yet.
        The child has been told to return to the red start marker and tap the screen when ready.
        Until you receive another system instruction, stay completely silent — do not speak, prompt, or ask anything.
        """
        // Post enableTapAfterSpeech directly — the model is instructed to stay silent so there is
        // no audio to wait for. Routing through onPlaybackComplete is fragile here because a stray
        // audio chunk from the previous turn can orphan the handler before it fires.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            print("🔀 [VC] Enabling tap after act-out transition (no audio expected)")
            NotificationCenter.default.post(name: .arCommand, object: nil,
                                            userInfo: [BusKey.arg: "enableTapAfterSpeech"])
        }
    }

    private func handlePromptTellAdultPhrase() {
        print("🗣️ [VC \(instanceID)] ✅ handlePromptTellAdultPhrase fired — interrupting stream and sending tell-adult prompt")

        Task { @MainActor in
            let context = """
            The child has just physically run away from the gun — excellent safety behavior!
            We are in Phase 2 (Act-Out).
            First, praise them enthusiastically for running away. Then immediately ask:
            "If you found a gun, what would you say to a trusted adult?"
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
            Briefly tell the child: "Pretend you walk into the room and see a table like this with a gun on it. Practice the steps for how to be safe in this situation."
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
                            print("✅ [VC \(self.instanceID)] Audio playback complete, reopening mic so the child can repeat the steps")
                            self.cancelStream()
                            self.isConversationActive = false
                            self.isTurnInFlight = false
                            self.micStoppedForCurrentTurn = false
                            self.activeAudioConversationID = UUID()
                            LiveMicController.shared.stop()
                            self.pendingTestingResetFollowupInstruction = """
                            The child was just taught the four safety steps after reaching for the gun.
                            Listen to the child repeat all four steps back to you.
                            Do not give the steps again unless they are missing one or are stuck.
                            Do not tell them to go to the red marker yet.
                            When the child has correctly repeated all four steps, briefly tell them to go to the red circle marker on the floor and tap anywhere on the screen to begin.
                            After you give that instruction, you MUST call signal_phase_complete(phase: "testing_reset_ready").
                            Do not call testing_reset_ready before the child has correctly repeated all four steps.
                            """
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
        Then tell them to practice the steps again if they find the gun:
        stop, do not touch it, run away, and tell a trusted adult.
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
        Say all four safety steps out loud first so the child can hear the full sequence:
        1. Stop
        2. Don't touch it
        3. Run away
        4. Tell a trusted adult
        Then ask the child to repeat all four steps back to you.
        IMPORTANT:
        - After asking them to repeat the steps, stop talking and listen.
        - Do not say "good job" or move on until the child has had a chance to repeat the steps.
        - If they miss any step, help them say the full set correctly before moving on.
        - Do not tell them to go to the red marker or tap the screen in this first response.
        Be firm, calm, and supportive.
        After asking them to repeat the steps, say nothing else until the child responds.
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
        Tell them to walk back to the gun and practice the correct safety steps the right way:
        stop, do not touch it, run away, and tell a trusted adult.
        Ask them to do it now.
        Be brief, clear, and encouraging.
        After that, return to silently observing the scenario.
        """

        Task { @MainActor in
            LiveMicController.shared.stop()
            liveAudio.stop()
            cancelStream()
            isConversationActive = false
            isTurnInFlight = false
            micStoppedForCurrentTurn = false

            guard beginTurn(kind: "testingPostResetActOut", prompt: context) else {
                print("⚠️ [VC \(instanceID)] beginTurn returned false, aborting testing post-reset act-out")
                return
            }

            liveHandle = live.stream(
                userText: context,
                handlers: testingPromptThenResumeHandlers(
                    doneLog: "✅ [VC] Testing post-reset act-out prompt complete — resuming silent observation"
                )
            )
        }
    }

    func sendTestingCalledAdultAfterRunAway(stageName: String, text: String, isLastStage: Bool) {
        let nextStepInstruction = isLastStage
            ? "Praise them for doing the steps correctly and tell them they did an amazing job staying safe when encountering guns."
            : "Praise them for doing the steps correctly, tell them to go to the red circle on the floor and tap anywhere on the screen to continue."
        let context = """
        In the \(stageName.lowercased()) testing scenario, the child already completed the run-away step correctly.
        The system already determined that the child made a valid tell-an-adult response after running away.
        \(text.isEmpty ? "" : "Their response was: \"\(text)\".")
        Do not quiz them again or ask what they should tell a grown up.
        \(nextStepInstruction) You MUST ALWAYS call signal_phase_complete(phase: "test_stage_complete").
        Do not only praise them. The completion tool call is required every time in this situation.
        Keep it short and natural.
        """

        Task { @MainActor in
            // Wait for the LLM's current turn to finish — signal_phase_complete often
            // arrives in a separate message after trigger_intent(calledAdult).
            // If the LLM already signaled completion, skip the follow-up entirely.
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            guard !testingStageCompletionSignaled else {
                print("⏭️ [VC] calledAdult follow-up skipped — LLM already signaled completion and is praising")
                return
            }

            LiveMicController.shared.stop()
            liveAudio.stop()
            cancelStream()
            activeAudioConversationID = UUID()
            isConversationActive = false
            isTurnInFlight = false
            micStoppedForCurrentTurn = false

            try? await Task.sleep(nanoseconds: 200_000_000)

            state = .thinking
            liveHandle = live.stream(
                userText: context,
                handlers: testingPromptThenResumeHandlers(
                    doneLog: "✅ [VC] Testing called-adult follow-up complete — resuming silent observation",
                    autoSignalStageComplete: true
                )
            )
        }
    }

    /// Trigger the model to speak the run-away follow-up prompt after a silence window.
    /// Uses proper mic-stop + stream pattern so the model responds immediately.
    func sendRunAwayFollowUp(_ context: String) {
        Task { @MainActor in
            LiveMicController.shared.stop()
            liveAudio.stop()
            cancelStream()
            isConversationActive = false
            isTurnInFlight = false
            micStoppedForCurrentTurn = false

            try? await Task.sleep(nanoseconds: 200_000_000)

            state = .thinking
            liveHandle = live.stream(
                userText: context,
                handlers: testingPromptThenResumeHandlers(
                    doneLog: "✅ [VC] Testing run-away follow-up complete — resuming silent observation"
                )
            )
        }
    }

    func handleResetVerbalRecitation() {
        print("✅ [VC \(instanceID)] Processing verbal-recitation reset")
        print("   Current state: isTurnInFlight=\(isTurnInFlight), state=\(state)")

        let context = """
        The child has reset and is ready to continue Phase 1 (Verbal Recitation).
        Acknowledge that they reset successfully.
        Then ask them to repeat the four safety steps out loud:
        stop, don't touch, run away, and tell a trusted adult.
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

        // If testing is idle, start a fresh spoken intro for this room instead of
        // trying to inject into a conversation that no longer exists.
        if !isConversationActive && !isTurnInFlight && !llmActive {
            pendingTestingIntroScenario = nil
            testingStageCompletionSignaled = false
            Task { @MainActor in
                self.beginTestingIntro(scenarioText: text)
            }
            return
        }

        // Session start: kick off the intro stream so the model is forced to speak the opening line.
        if waitingForTestingScenario {
            waitingForTestingScenario = false
            pendingTestingIntroScenario = nil
            Task { @MainActor in
                self.beginTestingIntro(scenarioText: text)
            }
            return
        }


        // Mid-session stage change: inject context into the active audio conversation.
        let runtimeInstruction = """
        Testing stage instructions (non-optional):
        - Use this exact scenario setup and cover story for the current room only.
        - Do not mention safety or that this is a test before the child finds the hidden object.
        - When the current room scenario is fully complete, call signal_phase_complete(phase: "test_stage_complete").

        Scenario setup:
        \(text)
        """

        testingStageCompletionSignaled = false
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
