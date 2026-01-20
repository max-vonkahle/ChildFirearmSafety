//
//  StereoConfig.swift
//  Child Gun Safety
//
//  Created by Max on 10/5/25.
//


// StereoConfig.swift
import Foundation
import CoreGraphics

struct StereoConfig {
    /// Interpupillary distance in meters (typical adult ~0.064 m).
    var ipdMeters: Float = 0.064
    /// Near/far planes for per-eye projection.
    var zNear: Float = 0.001
    var zFar:  Float = 100.0
    /// Divider width in pixels (purely cosmetic; you can also keep using CardboardOverlay).
    var dividerWidthPx: CGFloat = 4
    /// Zero parallax distance - objects at this distance appear at screen depth (no doubling).
    /// Objects closer than this will appear to "pop out", objects farther will appear "behind" the screen.
    /// Typical values: 0.5m - 2.0m depending on your content.
    var zeroParallaxDistance: Float = 1.0
}