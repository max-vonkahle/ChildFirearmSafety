//
//  CardboardFit.swift
//  Child Gun Safety
//
//  Created by Max on 10/5/25.
//


//
//  CardboardFit.swift
//  Child Gun Safety
//
//  A tiny ObservableObject for tuning how the on-screen overlay aligns
//  with different Cardboard-style viewers. Values are in *screen pixels*.
//
//  Use with CardboardOverlay via `.environmentObject(CardboardFit())`.
//
//  NOTE: This is for alignment/cropping/vignetting only.
//  It does not do lens distortion correction (that requires Metal).
//

import SwiftUI

@MainActor
final class CardboardFit: ObservableObject {
    /// Width of the center divider (pixels).
    @Published var dividerWidth: CGFloat = 4

    /// Interpupillary distance in *pixels* between lens centers.
    /// If 0, the overlay defaults to using half of the screen width between centers.
    @Published var ipdPx: CGFloat = 0

    /// Vertical offset (pixels) to nudge the lens centers up/down.
    @Published var verticalOffset: CGFloat = 0

    /// Hard edge mask at far left and right (pixels) to hide lens edge/glare.
    @Published var edgeMask: CGFloat = 12

    /// Strength of radial vignetting per eye (0.0 = none, 1.0 = strong).
    @Published var vignetteStrength: CGFloat = 0.35

    /// Enable any calibration HUD you might add later (sliders, etc.).
    @Published var showCalibration: Bool = false
}