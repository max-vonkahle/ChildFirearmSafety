//
//  ContentView.swift
//  Child Gun Safety
//
//  Created by Max on 9/22/25.
//

import SwiftUI

enum ARMode { case create, load }

struct ContentView: View {
    let mode: ARMode
    @Binding var cardboardMode: Bool

    // Create mode state
    @State private var isArmed = false
    @State private var clearTick = 0

    // Save popup (Create mode)
    @State private var showSaveSheet = false
    @State private var roomId = ""


    // Load mode state
    @State private var selectedRoom: String? = nil    // set after user chooses from list
    @State private var didAutoLoad = false            // prevent duplicate auto-load

    // Overlay controls visibility
    @State private var showControls = false
    @State private var autoHideTask: Task<Void, Never>? = nil

    var body: some View {
        Group {
            if mode == .load && selectedRoom == nil {
                // 1) ROOM PICKER FIRST (no AR yet)
                RoomPickerView(
                    rooms: listSavedRooms(),
                    onPick: { name in
                        selectedRoom = name
                        didAutoLoad = false
                    }
                )
            } else {
                // 2) AR SCENE (Create flow, or Load after a selection)
                VStack {
                    ZStack {
                        ARViewContainer(
                            isArmed: $isArmed,
                            clearTick: $clearTick,
                            onDisarm: { isArmed = false }
                        )
                        .edgesIgnoringSafeArea(.all)
                        .scaleEffect(cardboardMode ? 0.98 : 1.0) // slight inset for lens edges

                        if cardboardMode {
                            StereoARContainer()                 // true stereo
                                .ignoresSafeArea()
                            CardboardOverlay()                  // keep your overlay for divider/edge masks
                                .ignoresSafeArea()
                        } else {
                            ARViewContainer(isArmed: $isArmed,
                                            clearTick: $clearTick,
                                            onDisarm: { isArmed = false })
                                .ignoresSafeArea()
                        }
                    }
                    .onAppear {
                        // Auto-load once when entering AR with a chosen room
                        if mode == .load, let name = selectedRoom, didAutoLoad == false {
                            NotificationCenter.default.post(
                                name: .loadWorldMap,
                                object: nil,
                                userInfo: ["roomId": name]
                            )
                            didAutoLoad = true
                        }
                    }
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showControls.toggle()
                            }
                            if showControls {
                                scheduleAutoHideControls()
                            } else {
                                autoHideTask?.cancel()
                                autoHideTask = nil
                            }
                        }
                    )
                    .overlay(alignment: .bottom) {
                        if showControls {
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
                                            .background(isArmed ? Color.yellow.opacity(0.3)
                                                                : Color.blue.opacity(0.25))
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

                                } else {
                                    // Load mode control bar (after a room is chosen)
                                    if let name = selectedRoom {
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
                                            // Go back to picker
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
                            }
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .padding(.bottom, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .animation(.easeInOut(duration: 0.2), value: showControls)
                        }
                    }

                }
                .sheet(isPresented: $showSaveSheet) {
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
                .onDisappear {
                    autoHideTask?.cancel()
                    autoHideTask = nil
                }
            }
        }
    }

    // Auto-hide controls a few seconds after they are shown
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

    // MARK: - Helpers

    /// Lists saved rooms by scanning the app's Documents directory for files
    /// like `room_<name>.arworldmap` (or any `.arworldmap`).
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
}

// MARK: - Inline room picker

private struct RoomPickerView: View {
    let rooms: [String]
    var onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if rooms.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 44))
                        Text("No saved rooms yet")
                            .font(.headline)
                        Text("Create a room first, then save it to see it here.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(rooms, id: \.self) { name in
                        Button {
                            onPick(name)
                        } label: {
                            HStack {
                                Image(systemName: "cube.transparent")
                                Text(name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Load Room")
        }
    }
}
