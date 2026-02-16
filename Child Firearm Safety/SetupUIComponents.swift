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
    let isArmed: Bool
    let canSave: Bool
    let placeLabel: String

    init(
        onClear: @escaping () -> Void,
        onPlace: @escaping () -> Void,
        onSave: @escaping () -> Void,
        isArmed: Bool = false,
        canSave: Bool = true,
        placeLabel: String = "Place"
    ) {
        self.onClear = onClear
        self.onPlace = onPlace
        self.onSave = onSave
        self.isArmed = isArmed
        self.canSave = canSave
        self.placeLabel = placeLabel
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onClear()
            } label: {
                Label("Clear", systemImage: "trash")
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }

            Button {
                onPlace()
            } label: {
                Label(placeLabel, systemImage: "plus.circle")
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(isArmed ? Color.blue.opacity(0.25) : Color.clear)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }

            Button {
                onSave()
            } label: {
                Label("Save Room", systemImage: "square.and.arrow.down")
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
            .disabled(!canSave)
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
