//
//  VoiceCoach.swift
//  Child Gun Safety
//
//  Created by Max on 9/23/25.
//

import Foundation
import AVFoundation
import Speech
import Accelerate

@MainActor
final class VoiceCoach: ObservableObject {
    enum State { case idle, listening, thinking, speaking }
    @Published private(set) var state: State = .idle
    @Published var transcript: String = ""

    private let asr = ASRController()
    private let tts = TTSController()
    private let llm = GeminiStreamingClient()

    // ⬇️ change from `let` to `lazy var` and build it in a closure
    private lazy var director: SpeechDirector = {
        let d = SpeechDirector(
            speak: { [weak self] text in self?.tts.speak(text) },
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
        tts.onStart  = { [weak d] in Task { @MainActor in d?.notifyTTSStart() } }
        tts.onFinish = { [weak d] in Task { @MainActor in d?.notifyTTSFinish() } }

        return d
    }()

    private var streamHandle: GeminiStreamHandle?
    private let systemPrompt = """
    You are a child-safety coach. Never explain how to handle or operate a gun.
    Focus only on: don't touch it, move away, and tell a trusted adult. Keep replies short (2–4 sentences).
    """
    private var llmActive = false

    init() {
        // ASR callbacks may fire off-main; hop to main
        asr.onPartial = { [weak self] _ in
            Task { @MainActor in
                if self?.state == .speaking { self?.bargeIn() }
            }
        }
        asr.onFinal = { [weak self] text in
            Task { @MainActor in
                print("[VC] onFinal -> \(text)")
                self?.handleUserUtterance(text)
            }
        }
        asr.onSpeechStart = { [weak self] in
            Task { @MainActor in
                if self?.state == .speaking { self?.bargeIn() }
            }
        }

        // Orchestrator → VoiceCoach
        NotificationCenter.default.addObserver(forName: .vcCommand, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let intent = note.userInfo?[BusKey.dialog] as? DialogueIntent else { return }
                self.interruptLLMAndTTS()
                self.speakScripted(intent)
            }
        }
    }

    /// Stop any ongoing LLM streaming and TTS so scripted coach lines don't double-speak.
    private func interruptLLMAndTTS() {
        cancelStream()
        director.clearAll()
        llmActive = false
    }

    /// Map DialogueIntent (from Orchestrator) to short, templated TTS lines.
    private func handleDialogueIntent(_ intent: DialogueIntent) {
        speakScripted(intent)
    }

    /// Enqueue a scripted DialogueIntent with high priority (preempts any LLM speech).
    private func speakScripted(_ intent: DialogueIntent) {
        // Single speaker label per intent
        self.append("\nCoach: ")
        switch intent {
        case .coverStoryIntro:
            director.enqueue("Your friend lost something in this room. Can you look around and help find it?", priority: .scriptedHigh)
        case .neutralExplorationPrompt(let area):
            if let a = area, !a.isEmpty {
                director.enqueue("Take a look near the \(a). What do you notice?", priority: .scriptedHigh)
            } else {
                director.enqueue("Take a look around and see what you notice.", priority: .scriptedHigh)
            }
        case .praiseBackedAway:
            director.enqueue("You stepped back and looked for help. That's the right thing to do. Nice job!", priority: .scriptedHigh)
        case .coachDontTouchWhy:
            director.enqueue("If you see something that could be dangerous, don't touch it. Step back and get a grown up.", priority: .scriptedHigh)
        case .answerWhatIsThat_safety:
            director.enqueue("We don't know for sure, and that means it could be unsafe. The safe choice is to step back and get a grown up.", priority: .scriptedHigh)
        case .answerIsThatReal_safety:
            director.enqueue("We can't tell if it's real. That makes it unsafe. Step back and find a grown up right away.", priority: .scriptedHigh)
        case .reflectionQ1:
            director.enqueue("If you see something like that again, what should you do?", priority: .scriptedHigh)
        }
    }

    func startSession() {
        Task { @MainActor in
            do {
                try VoicePerms.activateAudioSession()
                try await VoicePerms.requestMicrophone()     // ⬅️ add this
                try await VoicePerms.requestSpeech()
                VoicePerms.setModeListening()                // ⬅️ nice-to-have
                asr.setWantsRunning(true)
                try asr.start()
                state = .listening
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

        // For specific intents, let the Orchestrator drive the response via .vcCommand
        // and skip open-ended LLM to avoid double speech.
        switch routed {
        case .calledAdult, .askedWhatIsThat, .askedIsThatReal:
            // Do nothing else here; Orchestrator will push DialogueIntent and tts will handle onFinish → resume.
            return
        default:
            break
        }

        // Otherwise, continue with LLM streaming for general questions
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
                    }
                },
                onToken: { [weak self] chunk in
                    Task { @MainActor in self?.append(chunk) }
                },
                onSentence: { [weak self] sentence in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.director.enqueue(sentence)
                    }
                },
                onDone: { [weak self] in
                    Task { @MainActor in
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
        streamHandle = llm.stream(
            userText: text,
            systemPrompt: systemPrompt,
            temperature: 0.2,
            handlers: .init(
                onOpen: { [weak self] in Task { @MainActor in self?.transcript.append("\nCoach: ") } },
                onToken: { [weak self] chunk in Task { @MainActor in self?.transcript.append(chunk) } },
                onSentence: { [weak self] sentence in Task { @MainActor in self?.director.enqueue(sentence) } },
                onDone: { [weak self] in Task { @MainActor in
                    guard let self = self else { return }
                    if self.director.isSpeaking == false {
                        try? self.asr.start()
                        self.state = .listening
                    }
                }},
                onError: { [weak self] err in Task { @MainActor in
                    self?.transcript.append("\n[LLM error] \(err.localizedDescription)")
                    self?.director.clearAll()
                    try? self?.asr.start()
                    self?.state = .listening
                }}
            )
        )
    }

}
