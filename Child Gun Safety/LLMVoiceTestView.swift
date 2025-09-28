//
//  LLMVoiceTestView.swift
//  Child Gun Safety
//
//  Created by Max on 9/23/25.
//


import SwiftUI
import AVFoundation

struct LLMVoiceTestView: View {
    @State private var input = "What should I do if I see a gun at home?"
    @State private var output = ""
    private let speaker = AVSpeechSynthesizer()

    var body: some View {
        VStack(spacing: 12) {
            Text("Gemini Voice POC").font(.headline)
            TextField("Say something…", text: $input)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Ask Gemini") { Task { await ask() } }
                    .buttonStyle(.borderedProminent)

                Button("Stop Voice") { speaker.stopSpeaking(at: .immediate) }
                    .buttonStyle(.bordered)
            }

            ScrollView {
                Text(output).frame(maxWidth: .infinity, alignment: .leading)
                    .padding().background(Color(.secondarySystemBackground)).cornerRadius(8)
            }
        }
        .padding()
    }

    @MainActor
    private func ask() async {
        do {
            let system = """
            You are a child-safety coach. Do NOT give instructions on handling or operating firearms.
            Focus on: don't touch, move away, tell a trusted adult. Keep answers short (2–4 sentences).
            """
            let reply = try await GeminiClient.shared.chat(userText: input, systemPrompt: system)
            output = reply
            speak(reply)
        } catch {
            output = "Error: \(error.localizedDescription)"
            speak("Sorry, I ran into a problem.")
        }
    }

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = 0.48
        speaker.speak(u)
    }
}
