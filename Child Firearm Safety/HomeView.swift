//
//  HomeView.swift
//  Child Firearm Safety
//
//  Created by Max on 9/23/25.
//


import SwiftUI

struct HomeView: View {
    @AppStorage("cardboardMode") private var cardboardMode = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("Child Firearm Safety")
                        .font(.largeTitle).bold()


                // MARK: - Training Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Training")
                        .font(.title2)
                        .bold()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    NavigationLink {
                        SetupView(mode: .create)
                    } label: {
                        VStack(alignment: .leading) {
                            Label("Create Room", systemImage: "plus.circle")
                        }
                    }
                    NavigationLink {
                        SetupView(mode: .load)
                    } label: {
                        VStack(alignment: .leading) {
                            Label("Load Room", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Label("Training Setup", systemImage: "arkit")
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


                // MARK: - Testing Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Testing")
                        .font(.title2)
                        .bold()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    NavigationLink {
                        TestingSetupView(mode: .create)
                    } label: {
                        VStack(alignment: .leading) {
                            Label("Create Testing Room", systemImage: "plus.circle")
                        }
                    }
                    NavigationLink {
                        TestingSetupView(mode: .load)
                    } label: {
                        VStack(alignment: .leading) {
                            Label("Load Testing Room", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Label("Testing Setup", systemImage: "cube")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                NavigationLink {
                    TestingOrchestratorView()
                } label: {
                    Label("Safety Testing", systemImage: "checklist")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }


                // MARK: - Development Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Development")
                        .font(.title2)
                        .bold()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                NavigationLink {
                    RAGTestView()
                } label: {
                    Label("RAG System Test", systemImage: "brain")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.cyan.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                Text("Test the AI knowledge retrieval system")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                }
                .padding()
            }
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
    }
}

import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = UserDefaults.standard.string(forKey: "gemini_api_key") ?? ""
    @AppStorage("cardboardMode") private var cardboardMode = false
    @State private var saved = false
    
    // Training prompt - load custom if exists, otherwise show default
    @State private var systemPrompt: String = PromptDefaults.getTrainingPrompt()
    @State private var savedPrompt = false
    @State private var isCustomTrainingPrompt = PromptDefaults.hasCustomTrainingPrompt()
    
    // Testing prompt - load custom if exists, otherwise show default
    @State private var testingPrompt: String = PromptDefaults.getTestingPrompt()
    @State private var savedTestingPrompt = false
    @State private var isCustomTestingPrompt = PromptDefaults.hasCustomTestingPrompt()

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

            Section(header: Text("Training Prompt")) {
                Text("System prompt for Safety Training mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if isCustomTrainingPrompt {
                    Label("Using customized prompt", systemImage: "pencil.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else {
                    Label("Using default prompt", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }

                TextEditor(text: $systemPrompt)
                    .frame(minHeight: 200)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                HStack {
                    Button("Save Custom") {
                        let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        UserDefaults.standard.set(trimmed, forKey: PromptDefaults.trainingCustomKey)
                        savedPrompt = true
                        isCustomTrainingPrompt = true
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        #endif
                    }
                    .disabled(systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    
                    Spacer()
                    
                    if isCustomTrainingPrompt {
                        Button("Reset to Default", role: .destructive) {
                            PromptDefaults.resetTrainingPrompt()
                            systemPrompt = PromptDefaults.training
                            isCustomTrainingPrompt = false
                            savedPrompt = false
                            #if canImport(UIKit)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            #endif
                        }
                    }
                }
                if savedPrompt {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                }
            }

            Section(header: Text("Testing Prompt")) {
                Text("System prompt for Safety Testing mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if isCustomTestingPrompt {
                    Label("Using customized prompt", systemImage: "pencil.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else {
                    Label("Using default prompt", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }

                TextEditor(text: $testingPrompt)
                    .frame(minHeight: 200)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                HStack {
                    Button("Save Custom") {
                        let trimmed = testingPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        UserDefaults.standard.set(trimmed, forKey: PromptDefaults.testingCustomKey)
                        savedTestingPrompt = true
                        isCustomTestingPrompt = true
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        #endif
                    }
                    .disabled(testingPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    
                    Spacer()
                    
                    if isCustomTestingPrompt {
                        Button("Reset to Default", role: .destructive) {
                            PromptDefaults.resetTestingPrompt()
                            testingPrompt = PromptDefaults.testing
                            isCustomTestingPrompt = false
                            savedTestingPrompt = false
                            #if canImport(UIKit)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            #endif
                        }
                    }
                }
                if savedTestingPrompt {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Settings")
        .onChange(of: apiKey) { _, _ in
            saved = false
        }
        .onChange(of: systemPrompt) { _, _ in
            savedPrompt = false
        }
        .onChange(of: testingPrompt) { _, _ in
            savedTestingPrompt = false
        }
    }
}
