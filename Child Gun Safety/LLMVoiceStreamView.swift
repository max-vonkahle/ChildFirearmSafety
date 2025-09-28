//
//  LLMVoiceStreamView.swift
//  Child Gun Safety
//
//  Created by Max on 9/23/25.
//


import SwiftUI
import AVFoundation

struct LLMVoiceStreamView: View {
    @State private var input = "What should I do if I find a gun at home?"
    @State private var transcript = ""
    private let tts = AVSpeechSynthesizer()
    private let client = GeminiStreamingClient()

    var body: some View {
        VStack(spacing: 12) {
            Text("Gemini Streaming Voice").font(.headline)

            TextField("Say something…", text: $input)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Ask (Stream)") { startStream() }
                    .buttonStyle(.borderedProminent)

                Button("Stop Voice") { tts.stopSpeaking(at: .immediate) }
                    .buttonStyle(.bordered)
            }

            ScrollView {
                Text(transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
            }
        }
        .padding()
    }

    private func startStream() {
        transcript.removeAll()
        let system = """
        You are a child-safety coach. Never explain how to handle or operate a gun.
        Focus on: don’t touch it, move away, and tell a trusted adult. Keep replies short.
        """

        client.stream(userText: input, systemPrompt: system, temperature: 0.2, handlers:
            .init(onOpen: {
                append("[stream opened]\n")
            }, onToken: { chunk in
                append(chunk)
            }, onSentence: { sentence in
                speak(sentence)
            }, onDone: {
                append("\n[done]")
            }, onError: { err in
                append("\n[error] \(err.localizedDescription)")
                speak("Sorry, I ran into a problem.")
            })
        )
    }

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = 0.48
        tts.speak(u)
    }

    @MainActor private func append(_ s: String) { transcript += s }
}
