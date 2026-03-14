//
//  HomeView.swift
//  Child Firearm Safety
//
//  Created by Max on 9/23/25.
//


import SwiftUI
import ReplayKit

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

struct SettingsView: View {
    @State private var apiKey: String = UserDefaults.standard.string(forKey: "gemini_api_key") ?? ""
    @AppStorage("cardboardMode") private var cardboardMode = false
    @AppStorage("ragUseTFIDF") private var ragUseTFIDF = false
    @State private var saved = false

    var body: some View {
        Form {
            Section(header: Text("Display")) {
                Toggle("Cardboard Viewer Mode", isOn: $cardboardMode)
                    .toggleStyle(SwitchToggleStyle(tint: .blue))
            }

            Section(header: Text("Knowledge Retrieval"), footer: Text("Local mode uses keyword matching with no API calls. Default uses AI embeddings for better accuracy.")) {
                Toggle("Local Only (TF-IDF)", isOn: $ragUseTFIDF)
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
                    Button("Clear") {
                        apiKey = ""
                        UserDefaults.standard.removeObject(forKey: "gemini_api_key")
                        saved = true
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        #endif
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

@MainActor
final class SessionScreenRecorder: NSObject, RPPreviewViewControllerDelegate {
    static let shared = SessionScreenRecorder()

    private let recorder = RPScreenRecorder.shared()
    private var isRecording = false

    func startIfNeeded() {
        guard !isRecording else { return }

        recorder.isMicrophoneEnabled = false
        recorder.startRecording { [weak self] error in
            guard let self else { return }
            if let error {
                print("⚠️ [Recording] Failed to start screen recording: \(error.localizedDescription)")
                return
            }
            self.isRecording = true
            print("🎥 [Recording] Screen recording started")
        }
    }

    func stopIfNeeded() {
        guard isRecording else { return }

        recorder.stopRecording { [weak self] previewController, error in
            guard let self else { return }
            self.isRecording = false

            if let error {
                print("⚠️ [Recording] Failed to stop screen recording: \(error.localizedDescription)")
                return
            }

            guard let previewController else {
                print("⚠️ [Recording] No preview controller returned")
                return
            }

            previewController.previewControllerDelegate = self
            UIApplication.presentFromTop(previewController)
            print("🎥 [Recording] Screen recording stopped")
        }
    }

    func previewControllerDidFinish(_ previewController: RPPreviewViewController) {
        previewController.dismiss(animated: true)
    }
}

extension UIApplication {
    static func presentFromTop(_ viewController: UIViewController, animated: Bool = true) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let top = topViewController() else { return }
            top.present(viewController, animated: animated)
        }
    }

    static func topViewController(base: UIViewController? = nil) -> UIViewController? {
        let baseController = base ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController

        if let nav = baseController as? UINavigationController {
            return topViewController(base: nav.visibleViewController)
        }
        if let tab = baseController as? UITabBarController {
            return topViewController(base: tab.selectedViewController)
        }
        if let presented = baseController?.presentedViewController {
            return topViewController(base: presented)
        }
        return baseController
    }
}
