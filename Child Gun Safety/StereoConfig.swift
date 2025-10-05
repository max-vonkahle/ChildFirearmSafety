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
    var zNear: Float = 0.01
    var zFar:  Float = 10.0
    /// Divider width in pixels (purely cosmetic; you can also keep using CardboardOverlay).
    var dividerWidthPx: CGFloat = 4
}