//
//  SetupView.swift
//  Child Firearm Safety
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
    @State private var selectedAsset: String? = nil
    @State private var hasPlacedAssets = false

    // Save popup (Create mode)
    @State private var showSaveSheet = false
    @State private var roomId = ""

    // Load mode state
    @State private var selectedRoom: String? = nil
    @State private var didAutoLoad = false
    @State private var roomNames: [String] = RoomLibrary.savedRooms()

    @Environment(\.dismiss) private var dismiss

    // Overlay controls visibility
    @State private var showControls = false
    @State private var autoHideTask: Task<Void, Never>? = nil

    // Shared UI state
    @StateObject private var uiState = SetupUIState()

    var body: some View {
        Group {
            if mode == .load && selectedRoom == nil {
                // SHOW NAV BAR on picker so the Back button appears
                RoomPickerView(
                    title: "Load Room",
                    rooms: roomNames,
                    onPick: { name in
                        selectedRoom = name
                        didAutoLoad = false
                    },
                    onDelete: { name in
                        RoomLibrary.delete(name)
                        roomNames = RoomLibrary.savedRooms()
                    }
                )
                .onAppear { roomNames = RoomLibrary.savedRooms() }
            } else {
                ZStack {
                    ARSceneView(
                        isArmed: $isArmed,
                        clearTick: $clearTick,
                        selectedAsset: $selectedAsset,
                        onDisarm: { isArmed = false },
                        onSceneAppear: handleSceneAppear,
                        onSceneTap: handleSceneTap,
                        onExit: performExit
                    ) {
                        VStack {
                            if mode == .create {
                                SetupInstructionOverlay(
                                    state: uiState,
                                    steps: [
                                        "Move device around to scan the area",
                                        "Tap screen to show controls",
                                        "Place table (gun auto-places on top)",
                                        "Save room when finished"
                                    ]
                                )
                            }
                            Spacer()
                            if showControls { controlsOverlay }
                        }
                    }
                }
                .ignoresSafeArea()
                .sheet(isPresented: $showSaveSheet) { saveSheet }
                .onDisappear {
                    cleanupAutoHide()
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationBarBackButtonHidden(true)
            }
        }
        .onChange(of: showSaveSheet) { _, isShowing in
            if !isShowing {
                roomNames = RoomLibrary.savedRooms()
            }
        }
        .onChange(of: isArmed) { oldValue, newValue in
            // When isArmed goes from true to false, it means placement happened
            if oldValue == true && newValue == false {
                hasPlacedAssets = true
            }
        }
        .onChange(of: clearTick) { _, _ in
            // When clear is triggered, reset the placement flag
            hasPlacedAssets = false
        }
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
        if mode == .create {
            SetupControlButtons(
                onClear: {
                    clearTick &+= 1
                },
                onPlace: {
                    selectedAsset = "table"
                    isArmed = true
                },
                onSave: {
                    showSaveSheet = true
                },
                isArmed: isArmed,
                canSave: hasPlacedAssets
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: showControls)
        } else {
            EmptyView()
        }
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

    private func performExit() {
        dismiss()
    }
}
