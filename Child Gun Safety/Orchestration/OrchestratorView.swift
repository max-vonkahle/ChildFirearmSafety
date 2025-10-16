//
//  OrchestratorView.swift
//  Child Gun Safety
//
//  Created by Max on 9/25/25.
//

import SwiftUI

struct OrchestratorView: View {
    @StateObject private var orch = Orchestrator()
    @StateObject private var coach = VoiceCoach()

    @State private var isArmed = false
    @State private var clearTick = 0
    @State private var selectedRoom: String? = nil
    @State private var didAutoLoad = false
    @State private var didAutoStart = false

    var body: some View {
        Group {
            if selectedRoom == nil {
                RoomPickerView(
                    title: "Choose a Room",
                    emptyMessage: "Create a room first, then save it to see it here.",
                    rooms: RoomLibrary.savedRooms()
                ) { name in
                    selectedRoom = name
                }
            } else {
                ARSceneView(
                    isArmed: $isArmed,
                    clearTick: $clearTick,
                    onDisarm: { isArmed = false },
                    onSceneAppear: handleSceneAppear
                ) {
                    safetyOverlay
                }
                .onDisappear { stopSession() }
            }
        }
        .navigationTitle("Safety Training")
        .navigationBarTitleDisplayMode(.inline)
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

    @ViewBuilder
    private var safetyOverlay: some View {
        HStack(spacing: 16) {
            Button("Change Room") { changeRoom() }
            Button("Stop") { stopSession() }
            Spacer()
            Text(phaseLabel(orch.phase))
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.bottom, 16)
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
