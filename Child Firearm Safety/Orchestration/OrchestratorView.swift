//
//  OrchestratorView.swift
//  Child Firearm Safety
//
//  Created by Max on 9/25/25.
//

import SwiftUI

struct OrchestratorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var orch = Orchestrator()
    @StateObject private var coach = VoiceCoach()
    @AppStorage("cardboardMode") private var cardboardMode = false
    @AppStorage("sessionRecordingEnabled") private var sessionRecordingEnabled = false

    @State private var isArmed = false
    @State private var clearTick = 0
    @State private var selectedRoom: String? = nil
    @State private var didAutoLoad = false
    @State private var didAutoStart = false
    @State private var roomNames: [String] = RoomLibrary.savedRooms()
    @State private var showHeadsetInstruction = false
    @State private var showLoadingScreen = true
    @State private var showStartPrompt = false
    @State private var showCamera = false
    @State private var hasConfiguredObserver = false
    @State private var showCompletionScreen = false
    @State private var isSessionRecordingActive = false
    @State private var assetsConfiguredObserver: NSObjectProtocol?
    @State private var completionObserver: NSObjectProtocol?
    @State private var loadingMappingStatus = "Waiting for relocalization"

    var body: some View {
        Group {
            if selectedRoom == nil {
                // SHOW NAV BAR (so Back appears)
                RoomPickerView(
                    title: "Choose a Room",
                    emptyMessage: "Create a room first, then save it to see it here.",
                    rooms: roomNames,
                    onPick: { name in
                        selectedRoom = name
                    },
                    onDelete: { name in
                        RoomLibrary.delete(name)
                        roomNames = RoomLibrary.savedRooms()
                    }
                )
                .onAppear { roomNames = RoomLibrary.savedRooms() }
            } else {
                ZStack {
                    // AR camera view - wrapped in EquatableView to prevent
                    // VoiceCoach state changes from triggering AR re-renders
                    EquatableView(content: StableARSceneView(
                        isArmed: $isArmed,
                        clearTick: $clearTick,
                        shouldRecordSession: isSessionRecordingActive && cardboardMode,
                        onDisarm: { isArmed = false },
                        onSceneAppear: handleSceneAppear,
                        onExit: {
                            stopSession()
                            dismiss()
                        }
                    ))
                    .opacity(showCamera ? 1 : 0)

                    // Microphone state indicator (top-right)
                    VStack {
                        MicIndicatorView(coach: coach)
                        Spacer()
                    }

                    // Black background shown until camera is revealed
                    if !showCamera {
                        Color.black
                            .ignoresSafeArea()
                    }

                    if showHeadsetInstruction {
                        HeadsetInstructionView {
                            withAnimation {
                                showHeadsetInstruction = false
                                showLoadingScreen = true
                            }
                        }
                    }

                    if showLoadingScreen {
                        LoadingScreenView(
                            onExit: {
                                stopSession()
                                cleanup()
                                selectedRoom = nil
                                didAutoLoad = false
                                didAutoStart = false
                            },
                            debugInfo: LoadingDebugInfo(mappingStatus: loadingMappingStatus)
                        )
                    }

                    if showStartPrompt {
                        StartTrainingPromptView {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                showStartPrompt = false
                                showCamera = true
                            }
                            isSessionRecordingActive = sessionRecordingEnabled
                            orch.startSession()
                            coach.startSession()
                            if sessionRecordingEnabled && !cardboardMode {
                                SessionScreenRecorder.shared.startIfNeeded()
                            }
                        }
                    }

                    if showCompletionScreen {
                        TrainingCompleteView {
                            showCompletionScreen = false
                            stopSession()
                            dismiss()
                        }
                        .transition(.opacity)
                    }
                }
                .onAppear {
                    showHeadsetInstruction = cardboardMode
                    showLoadingScreen = !cardboardMode
                }
                // HIDE NAV BAR only while in AR scene
                .toolbar(.hidden, for: .navigationBar)
                .navigationBarBackButtonHidden(true)
                .onDisappear {
                    if selectedRoom != nil {
                        stopSession()
                        cleanup()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .mappingStatusChanged)) { note in
                    let rawValue = note.userInfo?["status"] as? Int ?? 0
                    switch rawValue {
                    case 0: loadingMappingStatus = "Not Available"
                    case 1: loadingMappingStatus = "Limited"
                    case 2: loadingMappingStatus = "Extending"
                    case 3: loadingMappingStatus = "Mapped"
                    default: loadingMappingStatus = "Unknown"
                    }
                }
            }
        }
    }

    private func handleSceneAppear() {
        if let name = selectedRoom, !didAutoLoad {
            NotificationCenter.default.post(
                name: .loadWorldMap,
                object: nil,
                userInfo: ["roomId": name]
            )
            didAutoLoad = true
        }

        // Listen for assets configured notification - only add observer once
        if !hasConfiguredObserver {
            hasConfiguredObserver = true
            assetsConfiguredObserver = NotificationCenter.default.addObserver(
                forName: .assetsConfigured,
                object: nil,
                queue: .main
            ) { [self] _ in
                // Only show the start prompt if we're still loading
                if showLoadingScreen {
                    withAnimation {
                        showLoadingScreen = false
                        showStartPrompt = true
                    }
                }
            }
        }

        // Listen for training completion notification
        if completionObserver == nil {
            completionObserver = NotificationCenter.default.addObserver(
                forName: .trainingSessionComplete,
                object: nil,
                queue: .main
            ) { _ in
                withAnimation {
                    showCompletionScreen = true
                }
            }
        }
    }

    private func changeRoom() {
        stopSession()
        cleanup()
        selectedRoom = nil
        didAutoLoad = false
        didAutoStart = false
    }

    private func stopSession() {
        isSessionRecordingActive = false
        if sessionRecordingEnabled && !cardboardMode {
            SessionScreenRecorder.shared.stopIfNeeded()
        }
        orch.stopSession()
        coach.stopSession()
    }

    private func cleanup() {
        // Explicitly clean up VoiceCoach and Orchestrator observers
        coach.cleanup()
        orch.cleanup()

        if let observer = assetsConfiguredObserver {
            NotificationCenter.default.removeObserver(observer)
            assetsConfiguredObserver = nil
        }
        hasConfiguredObserver = false

        // Clean up completion observer
        if let observer = completionObserver {
            NotificationCenter.default.removeObserver(observer)
            completionObserver = nil
        }

        showHeadsetInstruction = false
        showLoadingScreen = true
        showStartPrompt = false
        showCamera = false
        showCompletionScreen = false
        loadingMappingStatus = "Waiting for relocalization"
    }

    private func phaseLabel(_ p: SessionPhase) -> String {
        switch p {
        case .verbalRecitation: return "Verbal Recitation"
        case .onboarding: return "Onboarding"
        case .awaitingActOutStart: return "Ready To Start"
        case .exploration: return "Exploration"
        case .encounterPending: return "Encounter"
        case .praisePath: return "Praise"
        case .resetLoop: return "Resetting"
        case .tellAdultPrompt: return "Tell Adult"
        case .completed: return "Completed"
        case .wrapup: return "Wrap-up"
        }
    }
}
