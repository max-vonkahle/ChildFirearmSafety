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
    @State private var hasPlacedMarker = false
    @State private var isMappingReady = false
    @State private var mappingStatusLabel = "Scanning area…"

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
                                        "Step ~3 feet from table, tap 'Mark Start' — marks child's starting spot",
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
        .onReceive(NotificationCenter.default.publisher(for: .mappingStatusChanged)) { note in
            guard mode == .create else { return }
            let rawValue = note.userInfo?["status"] as? Int ?? 0
            // Only enable save when fully mapped (rawValue 3); extending (2) is not reliable enough
            isMappingReady = (rawValue == 3)
            switch rawValue {
            case 0: mappingStatusLabel = "Scanning… move device around slowly"
            case 1: mappingStatusLabel = "More scanning needed — keep moving"
            case 2: mappingStatusLabel = "Almost ready — keep scanning a little more"
            case 3: mappingStatusLabel = "Fully mapped — ready to save"
            default: mappingStatusLabel = "Scanning…"
            }
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
                    hasPlacedMarker = false
                },
                onPlace: {
                    selectedAsset = "table"
                    isArmed = true
                },
                onSave: {
                    showSaveSheet = true
                },
                onMarker: {
                    NotificationCenter.default.post(name: .placeStartMarker, object: nil)
                    hasPlacedMarker = true
                },
                onClearMarker: {
                    NotificationCenter.default.post(name: .clearStartMarker, object: nil)
                    hasPlacedMarker = false
                },
                isArmed: isArmed,
                canSave: hasPlacedAssets && isMappingReady,
                mappingReady: isMappingReady,
                mappingStatusLabel: mappingStatusLabel,
                showMarkerButton: hasPlacedAssets,
                markerPlaced: hasPlacedMarker
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

                if !isMappingReady {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Scanning lost — move the device around to restore mapping before saving.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

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
                    .disabled(roomId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isMappingReady)
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
