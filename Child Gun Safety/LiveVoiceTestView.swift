//
//  LiveVoiceTestView.swift
//  Child Gun Safety
//
//  Created by Max on 11/30/25.
//


import SwiftUI

struct LiveVoiceTestView: View {
    @State private var input = "What should I do if I find a gun at home?"
    @State private var transcript = ""
    @State private var streamHandle: GeminiFlashLiveStreamHandle?

    private let client = GeminiFlashLiveClient.shared

    var body: some View {
        VStack(spacing: 12) {
            Text("Gemini LIVE Test").font(.headline)

            TextField("Prompt…", text: $input)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            HStack {
                Button("Ask (Live Voice)") { startStream() }
                    .buttonStyle(.borderedProminent)

                Button("Stop") { stopStream() }
                    .buttonStyle(.bordered)
            }

            ScrollView {
                Text(transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .padding()
    }

    private func startStream() {
        stopStream()                     // cancel any previous
        transcript = ""                  // clear text
        LiveAudioPlayer.shared.stop()    // clear audio

        let prompt = """
        You are a child-safety coach. Never explain how to handle or operate a gun.
        Focus on: don’t touch it, move away, and tell a trusted adult. Keep replies short.

        Child: \(input)
        """

        streamHandle = client.stream(
            userText: prompt,
            handlers: GeminiFlashLiveClient.Handlers(
                onOpen: {
                    append("[session opened]\n")
                },
                onTextDelta: { text in
                    append(text)       // optional text transcript
                },
                onAudioReady: { data, sampleRate in
                    LiveAudioPlayer.shared.playPCM16(data, sampleRate: sampleRate)
                },
                onDone: {
                    append("\n[done]\n")
                },
                onError: { err in
                    append("\n[error] \(err.localizedDescription)\n")
                    LiveAudioPlayer.shared.stop()
                }
            )
        )
    }

    private func stopStream() {
        streamHandle?.cancel()
        LiveAudioPlayer.shared.stop()
        append("\n[stopped]\n")
    }

    @MainActor
    private func append(_ s: String) {
        transcript += s
    }
}
