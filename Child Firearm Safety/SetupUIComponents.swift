//
//  SetupUIComponents.swift
//  Child Firearm Safety
//
//  Shared UI components for Training and Testing setup views
//

import SwiftUI
import UIKit

// MARK: - Shared State for Setup UI

class SetupUIState: ObservableObject {
    @Published var instructionText: String = ""
    @Published var instructionStyle: InstructionStyle = .neutral
    @Published var showSkipButton: Bool = false
    @Published var instructionsExpanded: Bool = true

    var skipAction: (() -> Void)?

    enum InstructionStyle {
        case neutral, primary, success, warning

        var color: Color {
            switch self {
            case .neutral:   return .black.opacity(0.6)
            case .primary:   return .blue.opacity(0.7)
            case .success:   return .green.opacity(0.7)
            case .warning:   return .orange.opacity(0.7)
            }
        }
    }
}

// MARK: - Collapsible Instruction Overlay

struct SetupInstructionOverlay: View {
    @ObservedObject var state: SetupUIState
    let steps: [String]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Setup Instructions")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        state.instructionsExpanded.toggle()
                    }
                } label: {
                    Image(systemName: state.instructionsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Color.white.opacity(0.2))
                        .clipShape(Circle())
                }
            }

            if state.instructionsExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).")
                                .font(.system(size: 14, weight: .semibold))
                            Text(step)
                                .font(.system(size: 14))
                        }
                    }
                }
                .foregroundStyle(.white)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.blue.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.top, 60)
    }
}

// MARK: - Dynamic Status Message Overlay

struct SetupStatusMessage: View {
    @ObservedObject var state: SetupUIState

    var body: some View {
        VStack(spacing: 12) {
            if !state.instructionText.isEmpty {
                Text(state.instructionText)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(state.instructionStyle.color)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if state.showSkipButton {
                Button("Skip") {
                    state.skipAction?()
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.top, 60)
    }
}

// MARK: - Bottom Control Buttons

struct SetupControlButtons: View {
    let onClear: () -> Void
    let onPlace: () -> Void
    let onSave: () -> Void
    var onMarker: (() -> Void)? = nil
    var onClearMarker: (() -> Void)? = nil
    let isArmed: Bool
    let canSave: Bool
    var mappingReady: Bool = false
    var mappingStatusLabel: String = "Scanning…"
    let placeLabel: String
    var showMarkerButton: Bool = false
    var markerPlaced: Bool = false

    init(
        onClear: @escaping () -> Void,
        onPlace: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onMarker: (() -> Void)? = nil,
        onClearMarker: (() -> Void)? = nil,
        isArmed: Bool = false,
        canSave: Bool = true,
        mappingReady: Bool = false,
        mappingStatusLabel: String = "Scanning…",
        placeLabel: String = "Place",
        showMarkerButton: Bool = false,
        markerPlaced: Bool = false
    ) {
        self.onClear = onClear
        self.onPlace = onPlace
        self.onSave = onSave
        self.onMarker = onMarker
        self.onClearMarker = onClearMarker
        self.isArmed = isArmed
        self.canSave = canSave
        self.mappingReady = mappingReady
        self.mappingStatusLabel = mappingStatusLabel
        self.placeLabel = placeLabel
        self.showMarkerButton = showMarkerButton
        self.markerPlaced = markerPlaced
    }

    var body: some View {
        VStack(spacing: 10) {
            // Mapping status indicator (shown when save is not yet available)
            if !mappingReady {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.white)
                    Text(mappingStatusLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.7))
                .cornerRadius(10)
            }

            // Primary row: Clear | Place | Save
            HStack(spacing: 12) {
                Button(action: onClear) {
                    Label("Clear", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }

                Button(action: onPlace) {
                    Label(placeLabel, systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isArmed ? Color.blue.opacity(0.25) : Color.clear)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }

                Button(action: onSave) {
                    Label("Save", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(canSave ? Color.green.opacity(0.25) : Color.clear)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }
                .disabled(!canSave)
                .opacity(canSave ? 1.0 : 0.4)
            }

            // Marker row: only shown after table is placed
            if showMarkerButton {
                Button(action: markerPlaced ? { onClearMarker?() } : { onMarker?() }) {
                    Label(
                        markerPlaced ? "Clear Start Marker" : "Mark Start Position",
                        systemImage: markerPlaced ? "mappin.slash" : "mappin"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(markerPlaced ? Color.green.opacity(0.2) : Color.clear)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.bottom, 20)
    }
}

// MARK: - Alert Helper

extension View {
    func showSetupAlert(title: String, message: String) {
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootViewController = windowScene.windows.first?.rootViewController else {
                return
            }

            let alert = UIAlertController(
                title: title,
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))

            // Find the topmost presented view controller
            var topController = rootViewController
            while let presented = topController.presentedViewController {
                topController = presented
            }

            topController.present(alert, animated: true)
        }
    }
}
