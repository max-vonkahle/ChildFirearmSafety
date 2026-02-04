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
                    // AR camera view - always loaded but initially hidden
                    ARSceneView(
                        isArmed: $isArmed,
                        clearTick: $clearTick,
                        onDisarm: { isArmed = false },
                        onSceneAppear: handleSceneAppear,
                        onExit: {
                            stopSession()
                            dismiss()
                        }
                    ) {
                        EmptyView() // No user-facing overlay
                    }
                    .onDisappear {
                        stopSession()
                        cleanup()
                    }
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
                        LoadingScreenView()
                    }

                    if showStartPrompt {
                        StartTrainingPromptView {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                showStartPrompt = false
                                showCamera = true
                            }
                            orch.startSession()
                            coach.startSession()
                        }
                    }
                }
                .onAppear {
                    showHeadsetInstruction = cardboardMode
                    showLoadingScreen = !cardboardMode
                }
                // HIDE NAV BAR only while in AR scene
                .toolbar(.hidden, for: .navigationBar)
                .navigationBarBackButtonHidden(true)
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
            NotificationCenter.default.addObserver(
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
    }

    private func changeRoom() {
        stopSession()
        cleanup()
        selectedRoom = nil
        didAutoLoad = false
        didAutoStart = false
    }

    private func stopSession() {
        orch.stopSession()
        coach.stopSession()
    }

    private func cleanup() {
        NotificationCenter.default.removeObserver(self, name: .assetsConfigured, object: nil)
        hasConfiguredObserver = false
        showHeadsetInstruction = false
        showLoadingScreen = true
        showStartPrompt = false
        showCamera = false
    }

    private func phaseLabel(_ p: SessionPhase) -> String {
        switch p {
        case .onboarding: return "Onboarding"
        case .exploration: return "Exploration"
        case .encounterPending: return "Encounter"
        case .praisePath: return "Praise"
        case .coachingPath: return "Coaching"
        case .reflection: return "Reflection"
        case .wrapup: return "Wrap-up"
        }
    }
}
