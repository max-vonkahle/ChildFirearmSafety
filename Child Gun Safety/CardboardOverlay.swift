//
//  CardboardOverlay.swift
//  Child Gun Safety
//
//  Viewer-fitting overlay for Cardboard-style headsets.
//  Uses CardboardFit to tune divider, edge masks, per-eye vignettes, and lens centers.
//

import SwiftUI

struct CardboardOverlay: View {
    @EnvironmentObject private var fit: CardboardFit
 
    /// Set to false if you never want to see the dashed calibration circles.
    var showGuides: Bool = true

    init(showGuides: Bool = true) {
        self.showGuides = showGuides
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let midX = size.width * 0.5

            // Derive lens centers in screen space (pixels)
            let ipd = fit.ipdPx > 0 ? fit.ipdPx : size.width * 0.50 // default: centers are half-screen apart
            let leftCX = midX - ipd * 0.5
            let rightCX = midX + ipd * 0.5
            let cY = size.height * 0.5 + fit.verticalOffset

            ZStack {
                // Transparent base to occupy the full screen
                Color.clear.ignoresSafeArea()

                // Hard edge masks (left & right) to hide lens edge artifacts
                HStack(spacing: 0) {
                    Rectangle()
                        .frame(width: max(fit.edgeMask, 0))
                    Spacer(minLength: 0)
                    Rectangle()
                        .frame(width: max(fit.edgeMask, 0))
                }
                .foregroundStyle(.black)
                .ignoresSafeArea()

                // Center divider (nose bridge area)
                Rectangle()
                    .frame(width: max(fit.dividerWidth, 1))
                    .foregroundStyle(.black)
                    .ignoresSafeArea()

                // Per-eye radial vignettes (approximate lens falloff).
                // Left eye vignette
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(fit.vignetteStrength), location: 1.0),
                    ]),
                    center: UnitPoint(
                        x: max(0, min(1, leftCX / size.width)),
                        y: max(0, min(1, cY / size.height))
                    ),
                    startRadius: size.width * 0.18,
                    endRadius: size.width * 0.55
                )
                .ignoresSafeArea()
                .blendMode(.multiply)

                // Right eye vignette
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(fit.vignetteStrength), location: 1.0),
                    ]),
                    center: UnitPoint(
                        x: max(0, min(1, rightCX / size.width)),
                        y: max(0, min(1, cY / size.height))
                    ),
                    startRadius: size.width * 0.18,
                    endRadius: size.width * 0.55
                )
                .ignoresSafeArea()
                .blendMode(.multiply)

                // Optional visual guides to help you align the lens centers during calibration
                if showGuides || fit.showCalibration {
                    Group {
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: size.width * 0.38, height: size.width * 0.38)
                            .position(x: leftCX, y: cY)

                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: size.width * 0.38, height: size.width * 0.38)
                            .position(x: rightCX, y: cY)
                    }
                    .allowsHitTesting(false)
                }
            }
            .compositingGroup() // ensure blend modes are applied together
            .allowsHitTesting(false) // overlay should not block AR interactions
        }
    }
}
