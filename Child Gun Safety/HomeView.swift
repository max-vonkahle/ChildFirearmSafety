//
//  HomeView.swift
//  Child Gun Safety
//
//  Created by Max on 9/23/25.
//


import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Child Gun Safety")
                    .font(.largeTitle).bold()

                Text("Choose a mode to begin")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Menu {
                    NavigationLink {
                        ContentView(mode: .create)
                    } label: {
                        Label("Create Room (place gun)", systemImage: "plus.circle")
                    }
                    NavigationLink {
                        ContentView(mode: .load)
                    } label: {
                        Label("Load Room", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("AR Training", systemImage: "arkit")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                NavigationLink {
                    OrchestratorView()
                } label: {
                    Label("Start Safety Session (Voice + AR)", systemImage: "ear.and.waveform")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.purple.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                NavigationLink {
                    VoiceCoachView() // the voice-only screen you already have
                } label: {
                    Label("Start Voice Coach", systemImage: "mic.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Spacer()
            }
            .padding()
        }
    }
}
