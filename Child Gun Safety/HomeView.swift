//
//  HomeView.swift
//  Child Gun Safety
//
//  Created by Max on 9/23/25.
//


import SwiftUI

struct HomeView: View {
    @AppStorage("cardboardMode") private var cardboardMode = false
    @StateObject private var cardboardFit = CardboardFit()
    
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
                        SetupView(mode: .create)
                    } label: {
                        Label("Create Room", systemImage: "plus.circle")
                    }
                    NavigationLink {
                        SetupView(mode: .load)
                    } label: {
                        Label("Load Room", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("Setup", systemImage: "arkit")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                NavigationLink {
                    OrchestratorView()
                } label: {
                    Label("Safety Training", systemImage: "ear.and.waveform")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.purple.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Spacer()
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                            .imageScale(.large)
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .environmentObject(cardboardFit)
    }
}

import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = UserDefaults.standard.string(forKey: "gemini_api_key") ?? ""
    @AppStorage("cardboardMode") private var cardboardMode = false
    @State private var saved = false

    var body: some View {
        Form {
            Section(header: Text("Display")) {
                Toggle("Cardboard Viewer Mode", isOn: $cardboardMode)
                    .toggleStyle(SwitchToggleStyle(tint: .blue))
            }

            Section(header: Text("Gemini API Key")) {
                SecureField("Enter your Gemini API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                
                Link("Get a Gemini API Key", destination: URL(string: "https://aistudio.google.com/api-keys")!)
                    .font(.footnote)
                    .foregroundColor(.blue)
                    .padding(.top, 4)

                HStack {
                    Button("Paste") {
                        UIPasteboard.general.string.map { apiKey = $0 }
                    }
                    Spacer()
                    Button("Save") {
                        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        UserDefaults.standard.set(trimmed, forKey: "gemini_api_key")
                        saved = true
                        // Provide a subtle success haptic on save
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        #endif
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                }
            }

            Section(footer: Text("Your key is stored locally on this device. You can remove it anytime by clearing the text and tapping Save.")) {
                EmptyView()
            }
        }
        .navigationTitle("Settings")
        .onChange(of: apiKey) { _, _ in
            saved = false
        }
    }
}
