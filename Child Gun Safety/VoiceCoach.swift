//
//  VoiceCoach.swift
//  Child Gun Safety
//
//  Restored with Socratic systemPrompt
//

import Foundation
import AVFoundation
import Speech
import Accelerate

private extension Notification.Name {
    static let vcGunInView = Notification.Name("vcGunInView")
}

@MainActor
final class VoiceCoach: ObservableObject {
    enum State { case idle, listening, thinking, speaking }
    @Published private(set) var state: State = .idle
    @Published var transcript: String = ""   // for UI

    private let asr = ASRController()
    private let tts = GeminiTTSController()
    private let llm = GeminiStreamingClient()

    // Build SpeechDirector lazily to avoid init-order issues.
    private lazy var director: SpeechDirector = {
        let d = SpeechDirector(
            speak: { [weak self] text in
                Task { @MainActor in
                    guard let self else { return }
                    // Non-interrupting speak so the SpeechDirector controls sequencing
                    try? await self.tts.speak(text, interrupt: false)
                }
            },
            stopTTS: { [weak self] in self?.tts.stop() },
            pauseASR: { [weak self] in
                guard let self else { return }
                self.asr.setWantsRunning(false)
                self.asr.stop()
            },
            resumeASR: { [weak self] in
                guard let self else { return }
                self.asr.setWantsRunning(true)
                try? self.asr.start()
            }
        )
        // Wire TTS lifecycle (capture d, not self.director)
        tts.onStart  = { [weak d] in
            Task { @MainActor in
                print("[TTS] onStart")
                d?.notifyTTSStart()
            }
        }
        tts.onFinish = { [weak d] in
            Task { @MainActor in
                print("[TTS] onFinish")
                d?.notifyTTSFinish()
            }
        }
        return d
    }()

    private var streamHandle: GeminiStreamHandle?

    // New Socratic, question-forward prompt (non-didactic).
    private let systemPrompt = """
    You are a child‑safety coach guiding a young learner to *say the safe plan in their own words*.

    Core rules (never state as commands; elicit them through questions):
    • Don’t touch it. • Move away. • Tell a trusted adult.

    Style:
    - Be Socratic. Ask one short, concrete question at a time (6–14 words).
    - Avoid didactic language, instructions, or judgments. Do **not** say “you should…”.
    - Default to a single sentence. Only add a brief affirmation like “Nice thinking.” when helpful.
    - Never explain how to operate, handle, or identify a firearm or any weapon.
    - If the child asks “What do I do?” respond with a guiding question that leads them to name the three steps.
    - Prefer neutral phrasing like “something that might be unsafe” unless the child names the object.
    - Keep the conversation moving: acknowledge briefly, then ask a follow‑up question.
    - Do not ask about body positioning or hands unless the child explicitly asks; focus only on the three rules.
    - No lists in outputs; no emojis; no role‑play beyond being a calm coach.

    Your objective is to help the child independently state: don’t touch it, move away, and tell a trusted adult. Stay concise and question‑forward at all times.
    """

    // Lifecycle flag to coordinate LLM streaming and TTS playback
    private var llmActive = false

    // Conversation orchestration
    private enum Phase { case notStarted, introPlaying, storySaid_waitingForGun, gunInView_waiting, done }
    private var phase: Phase = .notStarted
    private var gunWaitTimer: Timer?

    init() {
        // ASR callbacks may fire off-main; hop to main
        asr.onPartial = { [weak self] _ in
            Task { @MainActor in
                if self?.state == .speaking { self?.bargeIn() }
            }
        }
        asr.onFinal = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                print("[ASR] final -> \(text)")
                // Any speech cancels a pending gun wait prompt.
                self.cancelGunWait()
                self.handleUserUtterance(text)
            }
        }
        asr.onSpeechStart = { [weak self] in
            Task { @MainActor in
                self?.cancelGunWait()
                if self?.state == .speaking { self?.bargeIn() }
            }
        }

        // Orchestrator → VoiceCoach
        NotificationCenter.default.addObserver(forName: .vcCommand, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let intent = note.userInfo?[BusKey.dialog] as? DialogueIntent else { return }
                self.interruptLLMAndTTS()
                self.streamFromEvent(intent)
            }
        }

        // AR → gun came into view (post .vcGunInView when AR detects it)
        NotificationCenter.default.addObserver(forName: .vcGunInView, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleGunInView() }
        }
    }

    /// Stop any ongoing LLM streaming and TTS so scripted coach lines don't double-speak.
    private func interruptLLMAndTTS() {
        cancelStream()
        director.clearAll()
        llmActive = false
    }

    func startSession() {
        Task { @MainActor in
            do {
                try VoicePerms.activateAudioSession()
                try await VoicePerms.requestMicrophone()
                try await VoicePerms.requestSpeech()
                VoicePerms.setModeListening()
                asr.setWantsRunning(true)
                try asr.start()
                state = .listening
                if self.phase == .notStarted {
                    self.scriptedIntro()
                }
            } catch {
                transcript.append("\n[ASR error] \(error.localizedDescription)")
                state = .idle
            }
        }
    }

    func stopSession() {
        asr.stop()
        cancelStream()
        director.clearAll()
        state = .idle
    }

    // LLM wrapper for coach turns using an observation line
    private func streamCoach(observation: String) {
        state = .thinking
        let userText = "Observation: \(observation)\nRespond with one short guiding question."
        print("[VC] → LLM (observation): \(userText)")
        var _dbg = ""
        streamHandle = llm.stream(
            userText: userText,
            systemPrompt: systemPrompt,
            temperature: 0.2,
            handlers: .init(
                onOpen: { [weak self] in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.llmActive = true
                        self.append("\nCoach: ")
                        _dbg = ""
                    }
                },
                onToken: { [weak self] chunk in
                    Task { @MainActor in
                        _dbg += chunk
                        self?.append(chunk)
                    }
                },
                onSentence: { [weak self] sentence in
                    Task { @MainActor in
                        print("[LLM] sentence -> \(sentence)")
                        self?.director.enqueue(sentence)
                    }
                },
                onDone: { [weak self] in
                    Task { @MainActor in
                        print("[LLM] final -> \(_dbg)")
                        guard let self = self else { return }
                        self.llmActive = false
                        if self.director.isSpeaking == false {
                            self.state = .listening
                            VoicePerms.setModeListening()
                            self.asr.setWantsRunning(true)
                            try? self.asr.start()
                        }
                    }
                },
                onError: { [weak self] err in
                    Task { @MainActor in
                        print("[LLM] error (partial) -> \(_dbg)")
                        guard let self = self else { return }
                        self.llmActive = false
                        self.append("\n[error] \(err.localizedDescription)")
                        self.director.clearAll()
                        self.state = .listening
                        VoicePerms.setModeListening()
                        self.asr.setWantsRunning(true)
                        try? self.asr.start()
                    }
                }
            )
        )
    }

    private func handleGunInView() {
        // Only start the wait window once the story has been delivered
        guard phase == .storySaid_waitingForGun else { return }
        phase = .gunInView_waiting
        startGunWait(seconds: 10)
    }

    private func startGunWait(seconds: TimeInterval) {
        cancelGunWait()
        gunWaitTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                // If still waiting (no user speech), nudge with a Socratic question.
                if self.phase == .gunInView_waiting {
                    self.streamCoach(observation: "An object that might be unsafe is visible, and the child is quiet for 10 seconds. Ask a short question like 'What should you do in this situation?'")
                    // remain in same phase; future actions will progress naturally
                }
            }
        }
    }

    private func cancelGunWait() {
        gunWaitTimer?.invalidate()
        gunWaitTimer = nil
    }
    

    /// Play a short, scripted intro via TTS, then hand off to LLM-driven flow.
    private func scriptedIntro() {
        Task { @MainActor in
            interruptLLMAndTTS()
            phase = .introPlaying
            print("[VC] scriptedIntro: begin")
            // Pause ASR so TTS can play cleanly
            asr.setWantsRunning(false)
            asr.stop()
            // Keep this concise and neutral; do not teach handling, only frame the activity.
            let intro = "Hi there. Let’s do a quick safety practice. Your friend needs help looking for their phone. Take a look around the room."
            do {
                print("[VC] scriptedIntro: speaking -> \(intro)")
                try await tts.speak(intro, interrupt: true)
                print("[VC] scriptedIntro: speak completed")
            } catch {
                // If TTS fails, fall back to transcript only
                append("\nCoach: \(intro)")
            }
            // After the scripted intro, begin waiting for the scene to unfold.
            phase = .storySaid_waitingForGun
            startGunWait(seconds: 10)
            // Resume listening so the child can respond immediately.
            state = .listening
            VoicePerms.setModeListening()
            asr.setWantsRunning(true)
            try? asr.start()
        }
    }

    /// Very small, rule-based intent router. Returns a VCIntent if matched and also posts it to NotificationCenter.
    private func routeAndPostIntent(from text: String) -> VCIntent? {
        let t = text.lowercased()
        let post: (VCIntent) -> Void = { intent in
            NotificationCenter.default.post(name: .vcIntent, object: nil, userInfo: [BusKey.vcintent: intent])
        }

        if t.contains("mom") || t.contains("dad") || t.contains("teacher") || t.contains("grown up") || t.contains("grown-up") || t.contains("help") {
            let i = VCIntent.calledAdult(text: text, conf: 0.8)
            post(i)
            return i
        }
        if t.contains("what is that") || t.contains("what's that") || t.contains("what is it") || t.contains("what's it") {
            let i = VCIntent.askedWhatIsThat(text: text, conf: 0.8)
            post(i)
            return i
        }
        if t.contains("is that real") || t.contains("is it real") {
            let i = VCIntent.askedIsThatReal(text: text, conf: 0.8)
            post(i)
            return i
        }
        let i = VCIntent.generalQuestion(text: text)
        post(i)
        return i
    }
    
    private enum PositiveAction {
        case moveAway
        case dontTouch
        case tellAdult(String?) // optional specific adult named
    }

    private func detectPositiveAction(in text: String) -> PositiveAction? {
        let t = text.lowercased()
        // Move away synonyms
        let movePhrases = ["move away","step back","back away","back up","move back","get away","go away from it"]
        if movePhrases.contains(where: { t.contains($0) }) { return .moveAway }

        // Don't touch synonyms
        let dontTouch = ["don't touch","do not touch","won't touch","not touch","no touching","i won't touch"]
        if dontTouch.contains(where: { t.contains($0) }) { return .dontTouch }

        // Tell adult / get help
        let adultPhrases = [
            "get an adult","get a grown up","get a grown-up","tell an adult","tell a grown up","tell a grown-up",
            "find an adult","tell someone","get help","tell my teacher","tell the teacher","tell mom","tell my mom",
            "tell dad","tell my dad"
        ]
        if adultPhrases.contains(where: { t.contains($0) }) {
            let knownAdults = ["mom","mother","dad","father","teacher","coach","nurse","principal","neighbor","security","officer"]
            let named = knownAdults.first(where: { t.contains($0) })
            return .tellAdult(named)
        }
        return nil
    }

    private func handlePositiveAction(_ action: PositiveAction) -> Bool {
        switch action {
        case .moveAway, .dontTouch:
            // Affirm, then ask for next step
            self.streamCoach(observation: "The child just said a correct safety step (e.g., moving away or not touching). Briefly affirm that choice, then ask: 'What should you do next?' as a single short question.")
            return true
        case .tellAdult(let named):
            if let who = named {
                self.streamCoach(observation: "The child said they'll tell a trusted adult and named \(who). Briefly affirm that choice, then ask a short follow-up like: 'How will you reach \(who) right now?'")
            } else {
                self.streamCoach(observation: "The child said they'll tell a trusted adult. Briefly affirm that choice, then ask: 'Which adult is around that you can tell?' as a single short question.")
            }
            return true
        }
    }

    private func handleUserUtterance(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try? asr.start()
            state = .listening
            return
        }

        // show what user said
        transcript.append("\n\nYou: \(text)")

        // move to thinking and stop listening to avoid echo
        asr.setWantsRunning(false)
        asr.stop()
        state = .thinking

        // Route to a coarse VCIntent and notify Orchestrator
        let routed = routeAndPostIntent(from: text)
        
        // If the child says a correct step, affirm and ask the appropriate next question.
        if let action = detectPositiveAction(in: text) {
            _ = handlePositiveAction(action)
            return
        }
        // Always continue with LLM for user utterances.

        // Otherwise, continue with LLM streaming for general questions
        print("[VC] → LLM (user): \(text)")
        var _dbg = ""
        streamHandle = llm.stream(
            userText: text,
            systemPrompt: systemPrompt,
            temperature: 0.2,
            handlers: .init(
                onOpen: { [weak self] in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.llmActive = true
                        self.append("\nCoach: ")
                        _dbg = ""
                    }
                },
                onToken: { [weak self] chunk in
                    Task { @MainActor in
                        _dbg += chunk
                        self?.append(chunk)
                    }
                },
                onSentence: { [weak self] sentence in
                    Task { @MainActor in
                        print("[LLM] sentence -> \(sentence)")
                        self?.director.enqueue(sentence)
                    }
                },
                onDone: { [weak self] in
                    Task { @MainActor in
                        print("[LLM] final -> \(_dbg)")
                        guard let self = self else { return }
                        self.llmActive = false
                        if self.director.isSpeaking == false {
                            self.state = .listening
                            VoicePerms.setModeListening()
                            self.asr.setWantsRunning(true)
                            try? self.asr.start()
                        }
                    }
                },
                onError: { [weak self] err in
                    Task { @MainActor in
                        print("[LLM] error (partial) -> \(_dbg)")
                        guard let self = self else { return }
                        self.llmActive = false
                        self.append("\n[error] \(err.localizedDescription)")
                        self.director.clearAll()
                        self.state = .listening
                        VoicePerms.setModeListening()
                        self.asr.setWantsRunning(true)
                        try? self.asr.start()
                    }
                }
            )
        )
    }

    /// Stream an LLM turn based on an external event (from the Orchestrator/AR).
    private func streamFromEvent(_ intent: DialogueIntent) {
        let observation: String
        switch intent {
        case .coverStoryIntro:
            observation = "The scene is starting. Invite the child to begin."
        case .neutralExplorationPrompt(let area):
            if let a = area, !a.isEmpty {
                observation = "The child is looking near the \(a)."
            } else {
                observation = "The child is looking around the room."
            }
        case .praiseBackedAway:
            observation = "The child stepped back from something that might be unsafe."
        case .coachDontTouchWhy:
            observation = "The child asked why they shouldn't touch something possibly unsafe."
        case .answerWhatIsThat_safety:
            observation = "The child asked 'What is that?' about a possibly unsafe object."
        case .answerIsThatReal_safety:
            observation = "The child asked if an object might be real."
        case .reflectionQ1:
            observation = "Prompt a reflection about what they would do next time."
        }

        // Compose an event-to-user text. The systemPrompt enforces Socratic style.
        let userText = "Observation: \(observation)\nRespond with one short guiding question."
        print("[VC] → LLM (event): \(userText)")
        // Move to thinking state and stream
        state = .thinking
        var _dbg = ""
        streamHandle = llm.stream(
            userText: userText,
            systemPrompt: systemPrompt,
            temperature: 0.2,
            handlers: .init(
                onOpen: { [weak self] in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.llmActive = true
                        self.append("\nCoach: ")
                        _dbg = ""
                    }
                },
                onToken: { [weak self] chunk in
                    Task { @MainActor in
                        _dbg += chunk
                        self?.append(chunk)
                    }
                },
                onSentence: { [weak self] sentence in
                    Task { @MainActor in
                        print("[LLM] sentence -> \(sentence)")
                        self?.director.enqueue(sentence)
                    }
                },
                onDone: { [weak self] in
                    Task { @MainActor in
                        print("[LLM] final -> \(_dbg)")
                        guard let self = self else { return }
                        self.llmActive = false
                        if self.director.isSpeaking == false {
                            self.state = .listening
                            VoicePerms.setModeListening()
                            self.asr.setWantsRunning(true)
                            try? self.asr.start()
                        }
                    }
                },
                onError: { [weak self] err in
                    Task { @MainActor in
                        print("[LLM] error (partial) -> \(_dbg)")
                        guard let self = self else { return }
                        self.llmActive = false
                        self.append("\n[error] \(err.localizedDescription)")
                        self.director.clearAll()
                        self.state = .listening
                        VoicePerms.setModeListening()
                        self.asr.setWantsRunning(true)
                        try? self.asr.start()
                    }
                }
            )
        )
    }

    private func bargeIn() {
        // If the user talks while we’re speaking, stop everything and listen.
        director.clearAll()
        cancelStream()
        llmActive = false
        state = .listening
        VoicePerms.setModeListening()
        asr.setWantsRunning(true)
        try? asr.start()
        append("\n[barge-in]")
    }

    private func cancelStream() {
        streamHandle?.cancel()
        streamHandle = nil
    }

    // Since the whole class is @MainActor, no extra annotation needed here.
    private func append(_ s: String) { transcript += s }
    
    // For the "Ping LLM" test button
    func handleTestPrompt(_ text: String) {
        transcript.append("\n\nYou: \(text)")
        state = .thinking
        var _dbg = ""
        streamHandle = llm.stream(
            userText: text,
            systemPrompt: systemPrompt,
            temperature: 0.2,
            handlers: .init(
                onOpen: { [weak self] in
                    Task { @MainActor in
                        self?.transcript.append("\nCoach: ")
                        _dbg = ""
                    }
                },
                onToken: { [weak self] chunk in
                    Task { @MainActor in
                        _dbg += chunk
                        self?.transcript.append(chunk)
                    }
                },
                onSentence: { [weak self] sentence in
                    Task { @MainActor in
                        print("[LLM] sentence -> \(sentence)")
                        self?.director.enqueue(sentence)
                    }
                },
                onDone: { [weak self] in
                    Task { @MainActor in
                        print("[LLM] final -> \(_dbg)")
                        guard let self = self else { return }
                        if self.director.isSpeaking == false {
                            try? self.asr.start()
                            self.state = .listening
                        }
                    }
                },
                onError: { [weak self] err in
                    Task { @MainActor in
                        print("[LLM] error (partial) -> \(_dbg)")
                        self?.transcript.append("\n[LLM error] \(err.localizedDescription)")
                        self?.director.clearAll()
                        try? self?.asr.start()
                        self?.state = .listening
                    }
                }
            )
        )
    }
}
