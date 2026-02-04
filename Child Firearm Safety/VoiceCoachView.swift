//
//  VoiceCoachView.swift
//  Child Firearm Safety
//
//  Created by Max on 9/23/25.
//


import SwiftUI

struct VoiceCoachView: View {
    @StateObject private var coach = VoiceCoach()

    var body: some View {
        VStack(spacing: 12) {
            Text("Voice Coach").font(.title2).bold()

            Text(statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Button(coach.state == .idle ? "Start" : "Stop") {
                    if coach.state == .idle { coach.startSession() } else { coach.stopSession() }
                }
                .buttonStyle(.borderedProminent)

                // Quick sanity tests:
                Button("Speak Test") { coachTestTTS() }.buttonStyle(.bordered)
                Button("Ping LLM") { coachTestLLM() }.buttonStyle(.bordered)
            }

            ScrollView {
                Text(coach.transcript.isEmpty ? "Transcript will appear here…" : coach.transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
            }
        }
        .padding()
        // ⬇️ Auto-start the session when this screen opens
        .onAppear { if coach.state == .idle { coach.startSession() } }
    }

    private var statusLine: String {
        switch coach.state {
        case .idle: return "Idle – tap Start"
        case .listening: return "Listening… (speak now)"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking… (talk to interrupt)"
        }
    }

    private func coachTestTTS() {
        // quick audible check without LLM/ASR
        coach.stopSession()
        Task { @MainActor in
            coach.startSession()
            coach.transcript += "\n[tts test]"
        }
    }

    private func coachTestLLM() {
        // force one LLM turn without ASR, just to verify the API key works
        coach.stopSession()
        Task { @MainActor in
            coach.handleTestPrompt("What should I do if I find a gun at home?")
        }
    }
}
