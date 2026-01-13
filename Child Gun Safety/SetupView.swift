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
    @State private var selectedAsset: String? = nil

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
                        if showControls { controlsOverlay }
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
            HStack(spacing: 12) {
                Button {
                    clearTick &+= 1
                } label: {
                    Label("Clear", systemImage: "trash")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }

                Menu {
                    Button("Place Table") {
                        selectedAsset = "table"
                        isArmed = true
                    }
                    Button("Place Gun") {
                        selectedAsset = "gun"
                        isArmed = true
                    }
                } label: {
                    Label("Place",
                          systemImage: "plus.circle")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color.blue.opacity(0.25))
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
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.bottom, 16)
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
