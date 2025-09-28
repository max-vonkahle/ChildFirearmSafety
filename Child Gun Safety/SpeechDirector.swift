//
//  SpeechDirector.swift
//  Child Gun Safety
//
//  Created by Max on 9/26/25.
//


// SpeechDirector.swift
import Foundation

@MainActor
final class SpeechDirector {
    enum Priority: Int { case normal = 0, scriptedHigh = 1 } // scripted preempts
    struct Utterance { let text: String; let priority: Priority }

    private var queue: [Utterance] = []
    private var speaking = false

    // Injected I/O closures so we don't depend on concrete TTS/ASR types
    private let speakFunc: (String) -> Void
    private let stopTTS: () -> Void
    private let pauseASR: () -> Void
    private let resumeASR: () -> Void

    init(speak: @escaping (String) -> Void,
         stopTTS: @escaping () -> Void,
         pauseASR: @escaping () -> Void,
         resumeASR: @escaping () -> Void) {
        self.speakFunc = speak
        self.stopTTS = stopTTS
        self.pauseASR = pauseASR
        self.resumeASR = resumeASR
    }

    // Owner should call these from TTS callbacks
    func notifyTTSStart() {
        pauseASR()
    }
    func notifyTTSFinish() {
        speaking = false
        dequeue()
        if !speaking && queue.isEmpty {
            resumeASR()
        }
    }

    func enqueue(_ text: String, priority: Priority = .normal) {
        let u = Utterance(text: text, priority: priority)
        if priority == .scriptedHigh {
            // Preempt: drop anything currently queued and stop current TTS
            queue.removeAll()
            stopTTS()
            speaking = false
            queue.insert(u, at: 0)
        } else {
            queue.append(u)
        }
        dequeue()
    }

    private func dequeue() {
        guard speaking == false, let next = queue.first else { return }
        queue.removeFirst()
        speaking = true
        speakFunc(next.text) // onStart will pause ASR; onFinish resumes in this class
    }

    var isSpeaking: Bool { speaking || !queue.isEmpty }
    func clearAll() {
        queue.removeAll()
        stopTTS()
        speaking = false
    }
}
