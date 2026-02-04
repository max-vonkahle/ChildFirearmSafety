//
//  MicIndicatorView.swift
//  Child Firearm Safety
//
//  Visual indicator showing microphone state during voice coaching
//

import SwiftUI

struct MicIndicatorView: View {
    @ObservedObject var coach: VoiceCoach
    @AppStorage("cardboardMode") private var cardboardMode = false

    var body: some View {
        HStack {
            // Microphone icon with state-based color (no background circle)
            Image(systemName: micIconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(micColor)
                .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
                .opacity(shouldShow ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: shouldShow)
                .animation(.easeInOut(duration: 0.2), value: coach.state)

            Spacer()
        }
        .padding(.top, topPadding)
        .padding(.leading, leadingPadding)
    }

    // Adjust padding based on cardboard mode to keep indicator in visible area
    private var topPadding: CGFloat {
        cardboardMode ? 70 : 24  // Closer to corner
    }

    private var leadingPadding: CGFloat {
        // In cardboard mode, need significant inset to be visible in left lens
        // Left lens is centered at ~25% of screen width with ~45% radius
        // So visible area starts around 21pt, we want to be safely inside at ~60pt
        cardboardMode ? 60 : 12
    }

    private var shouldShow: Bool {
        // Show indicator when coach is active (not idle)
        coach.state != .idle
    }

    private var micIconName: String {
        switch coach.state {
        case .idle:
            return "mic.slash.fill"
        case .listening:
            return "mic.fill"
        case .thinking:
            return "mic.slash.fill"
        case .speaking:
            return "mic.slash.fill"
        }
    }

    private var micColor: Color {
        switch coach.state {
        case .idle:
            return .gray
        case .listening:
            return .green  // Green = user can speak
        case .thinking:
            return .yellow  // Yellow = processing
        case .speaking:
            return .red  // Red = model is speaking, mic off
        }
    }
}
