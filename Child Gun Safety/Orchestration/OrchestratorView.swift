//
//  OrchestratorView.swift
//  Child Gun Safety
//
//  Created by Max on 9/25/25.
//

import SwiftUI

struct OrchestratorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var orch = Orchestrator()
    @StateObject private var coach = VoiceCoach()

    @State private var isArmed = false
    @State private var clearTick = 0
    @State private var selectedRoom: String? = nil
    @State private var didAutoLoad = false
    @State private var didAutoStart = false
    @State private var showExitUI = false

    var body: some View {
        Group {
            if selectedRoom == nil {
                // SHOW NAV BAR (so Back appears)
                RoomPickerView(
                    title: "Choose a Room",
                    emptyMessage: "Create a room first, then save it to see it here.",
                    rooms: RoomLibrary.savedRooms()
                ) { name in
                    selectedRoom = name
                }
            } else {
                ZStack(alignment: .topTrailing) {
                    ARSceneView(
                        isArmed: $isArmed,
                        clearTick: $clearTick,
                        onDisarm: { isArmed = false },
                        onSceneAppear: handleSceneAppear
                    ) {
                        EmptyView() // No user-facing overlay
                    }
                    .contentShape(Rectangle()) // Make the whole view tappable to reveal controls
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showExitUI = true
                        }
                        // Auto-hide after a short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showExitUI = false
                            }
                        }
                    }
                    if showExitUI {
                        Button {
                            stopSession()
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .imageScale(.large)
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Exit to Home")
                        .padding(.top, 12)
                        .padding(.trailing, 12)
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .onDisappear { stopSession() }
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

        if !didAutoStart {
            orch.startSession()
            coach.startSession()
            didAutoStart = true
        }
    }

    private func changeRoom() {
        stopSession()
        selectedRoom = nil
        didAutoLoad = false
        didAutoStart = false
    }

    private func stopSession() {
        orch.stopSession()
        coach.stopSession()
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
