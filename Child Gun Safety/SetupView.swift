//
//  SetupView.swift
//  Child Gun Safety
//
//  Flow for creating and loading AR rooms prior to safety training.
//

import SwiftUI

enum SetupMode { case create, load }

struct SetupView: View {
    let mode: SetupMode

    // Create mode state
    @State private var isArmed = false
    @State private var clearTick = 0

    // Save popup (Create mode)
    @State private var showSaveSheet = false
    @State private var roomId = ""

    // Load mode state
    @State private var selectedRoom: String? = nil
    @State private var didAutoLoad = false

    // Overlay controls visibility
    @State private var showControls = false
    @State private var autoHideTask: Task<Void, Never>? = nil

    var body: some View {
        Group {
            if mode == .load && selectedRoom == nil {
                RoomPickerView(
                    title: "Load Room",
                    rooms: RoomLibrary.savedRooms()
                ) { name in
                    selectedRoom = name
                    didAutoLoad = false
                }
            } else {
                ARSceneView(
                    isArmed: $isArmed,
                    clearTick: $clearTick,
                    onDisarm: { isArmed = false },
                    onSceneAppear: handleSceneAppear,
                    onSceneTap: handleSceneTap
                ) {
                    if showControls { controlsOverlay }
                }
                .sheet(isPresented: $showSaveSheet) { saveSheet }
                .onDisappear { cleanupAutoHide() }
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var navigationTitle: String {
        switch mode {
        case .create: return "Create Room"
        case .load: return selectedRoom.map { "Room: \($0)" } ?? "Load Room"
        }
    }

    // MARK: - Scene Callbacks
    private func handleSceneAppear() {
        guard mode == .load, let name = selectedRoom, didAutoLoad == false else { return }
        NotificationCenter.default.post(
            name: .loadWorldMap,
            object: nil,
            userInfo: ["roomId": name]
        )
        didAutoLoad = true
    }

    private func handleSceneTap() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }
        if showControls {
            scheduleAutoHideControls()
        } else {
            cleanupAutoHide()
        }
    }

    // MARK: - Overlays
    @ViewBuilder
    private var controlsOverlay: some View {
        HStack(spacing: 12) {
            if mode == .create {
                Button {
                    clearTick &+= 1
                } label: {
                    Label("Clear", systemImage: "trash")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }

                Button {
                    isArmed.toggle()
                } label: {
                    Label(isArmed ? "Tap to Place…" : "Place",
                          systemImage: isArmed ? "hand.point.up.left" : "plus.circle")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(isArmed ? Color.yellow.opacity(0.3) : Color.blue.opacity(0.25))
                        .cornerRadius(12)
                }

                Button {
                    showSaveSheet = true
                } label: {
                    Label("Save Room", systemImage: "square.and.arrow.down")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }
            } else if let name = selectedRoom {
                Button {
                    NotificationCenter.default.post(
                        name: .loadWorldMap,
                        object: nil,
                        userInfo: ["roomId": name]
                    )
                } label: {
                    Label("Reload \(name)", systemImage: "arrow.clockwise")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }

                Button {
                    selectedRoom = nil
                    didAutoLoad = false
                } label: {
                    Label("Change Room", systemImage: "list.bullet")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.bottom, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: showControls)
    }

    // MARK: - Save Sheet
    private var saveSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Name this room").font(.headline)

                TextField("e.g. living-room", text: $roomId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textFieldStyle(.roundedBorder)

                Spacer()
            }
            .padding()
            .navigationTitle("Save Room")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSaveSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        NotificationCenter.default.post(
                            name: .saveWorldMap,
                            object: nil,
                            userInfo: ["roomId": trimmed]
                        )
                        showSaveSheet = false
                    }
                    .disabled(roomId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Helpers
    private func scheduleAutoHideControls() {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls = false
            }
            autoHideTask = nil
        }
    }

    private func cleanupAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }
}
