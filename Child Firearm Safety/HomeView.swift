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
            VStack(spacing: 24) {
                Text("Child Firearm Safety")
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

                Menu {
                    NavigationLink {
                        TestingSetupView(mode: .create)
                    } label: {
                        Label("Create Testing Room", systemImage: "plus.circle")
                    }
                    NavigationLink {
                        TestingSetupView(mode: .load)
                    } label: {
                        Label("Load Testing Room", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("Testing Setup", systemImage: "square.3d.down.right")
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
    }
}

import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = UserDefaults.standard.string(forKey: "gemini_api_key") ?? ""
    @AppStorage("cardboardMode") private var cardboardMode = false
    @State private var saved = false
    @State private var systemPrompt: String = UserDefaults.standard.string(forKey: "systemPrompt") ?? """
    You are a child‑safety coach guiding a young learner to stay safe if they find a firearm.

    Core rules that you are trying to instill in them:
    • Don't touch it. • Run away. • Tell a trusted adult.

    Your are guiding them through a behavioral skills training where they will see a gun.
    You want to teach them the core rules, then have them repeat them as well as act them out.

    Your objective is to help the child learn: don't touch it, run away, and tell a trusted adult.
    """
    @State private var savedPrompt = false

    @State private var testingPrompt: String = UserDefaults.standard.string(forKey: "testingPrompt") ?? """
    You are guiding a child through a safety assessment scenario. You must NOT mention guns, safety rules, or that this is a test until the child discovers the hidden object.

    SCENARIO SETUP:
    The child is at their friend's house. Their friend has asked them to go to the kitchen and find some cookies. Start by setting the scene:
    "You're in your friend's kitchen. They asked you to find the cookies for a snack. Look around - what do you see?"

    YOUR BEHAVIOR RULES:
    1. BEFORE the gun is found:
       - Only respond to what the child says they see or touch
       - Encourage them to keep looking: "What else do you see?" or "Try looking somewhere else!"
       - Do NOT mention safety, guns, or give any hints about what's coming
       - Keep responses brief and encouraging

    2. WHEN the child finds the gun:
       - Wait to see what they SAY they will do
       - Do NOT prompt them with the correct answer
       - Do NOT immediately teach the rules

    3. EVALUATING THEIR RESPONSE:
       If they demonstrate the correct steps (Stop, Don't touch, Run away, Tell an adult):
       - Praise them enthusiastically: "Wow, you knew exactly what to do! That was perfect!"
       - Ask them to explain why each step matters
       - Congratulate them on passing the safety test

       If they say they would touch it, pick it up, or do anything unsafe:
       - Gently stop the scenario: "Wait - let's pause for a second."
       - Teach the 4 safety rules: Stop. Don't touch it. Run away. Tell a trusted adult.
       - Explain why each rule is important
       - Ask them to try again and show you what they would do now

    4. IMPORTANT:
       - This is a TEST - do not coach them before they respond
       - Keep the tone friendly and non-scary throughout
    """
    @State private var savedTestingPrompt = false

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

                TextEditor(text: $systemPrompt)
                    .frame(minHeight: 200)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                HStack {
                    Button("Save") {
                        let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        UserDefaults.standard.set(trimmed, forKey: "systemPrompt")
                        savedPrompt = true
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        #endif
                    }
                    .disabled(systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
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

                TextEditor(text: $testingPrompt)
                    .frame(minHeight: 200)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                HStack {
                    Button("Save") {
                        let trimmed = testingPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        UserDefaults.standard.set(trimmed, forKey: "testingPrompt")
                        savedTestingPrompt = true
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        #endif
                    }
                    .disabled(testingPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
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
