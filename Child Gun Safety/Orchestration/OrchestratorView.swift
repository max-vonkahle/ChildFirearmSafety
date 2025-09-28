//
//  OrchestratorView.swift
//  Child Gun Safety
//
//  Created by Max on 9/25/25.
//


import SwiftUI

struct OrchestratorView: View {
    @StateObject private var orch = Orchestrator()
    @StateObject private var coach = VoiceCoach()   // you already have this

    @State private var isArmed = false
    @State private var clearTick = 0
    @State private var selectedRoom: String? = nil
    @State private var didAutoLoad = false
    @State private var didAutoStart = false

    var body: some View {
        Group {
            if selectedRoom == nil {
                RoomPickerView(rooms: listSavedRooms()) { name in
                    selectedRoom = name
                }
            } else {
                VStack {
                    ARViewContainer(
                        isArmed: $isArmed,
                        clearTick: $clearTick,
                        onDisarm: { isArmed = false }
                    )
                    .edgesIgnoringSafeArea(.top)
                    .onAppear {
                        // Auto-load the chosen room once
                        if let name = selectedRoom, !didAutoLoad {
                            NotificationCenter.default.post(
                                name: .loadWorldMap,
                                object: nil,
                                userInfo: ["roomId": name]
                            )
                            didAutoLoad = true
                        }
                        // Auto-start session once
                        if !didAutoStart {
                            orch.startSession()
                            coach.startSession()
                            didAutoStart = true
                        }
                    }

                    // Dev bar: Change Room + Stop + Phase
                    HStack {
                        Button("Change Room") { selectedRoom = nil; didAutoLoad = false; didAutoStart = false }
                        Button("Stop") { orch.stopSession(); coach.stopSession() }
                        Spacer()
                        Text(phaseLabel(orch.phase))
                            .font(.caption).padding(6)
                            .background(.ultraThinMaterial).cornerRadius(8)
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                }
            }
        }
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

// MARK: - Helpers
private func listSavedRooms() -> [String] {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    guard let urls = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) else {
        return []
    }
    let names: [String] = urls.compactMap { url in
        guard url.pathExtension.lowercased() == "arworldmap" else { return nil }
        var base = url.deletingPathExtension().lastPathComponent
        if base.hasPrefix("room_") { base.removeFirst("room_".count) }
        return base
    }
    return names.sorted()
}

// Simple inline picker used before AR shows
private struct RoomPickerView: View {
    let rooms: [String]
    var onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if rooms.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray").font(.system(size: 44))
                        Text("No saved rooms yet").font(.headline)
                        Text("Create a room first, then save it to see it here.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(rooms, id: \.self) { name in
                        Button { onPick(name) } label: {
                            HStack {
                                Image(systemName: "cube.transparent")
                                Text(name)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Choose a Room")
        }
    }
}
