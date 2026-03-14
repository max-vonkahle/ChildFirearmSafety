//
//  StereoARContainer.swift
//  Child Firearm Safety
//
//  Created by Max on 10/5/25.
//


// StereoARContainer.swift
import SwiftUI

struct StereoARContainer: UIViewControllerRepresentable {
    var config = StereoConfig()
    var shouldRecordSession = false

    func makeUIViewController(context: Context) -> StereoARViewController {
        let controller = StereoARViewController(config: config)
        controller.shouldRecordSession = shouldRecordSession
        return controller
    }

    func updateUIViewController(_ vc: StereoARViewController, context: Context) {
        vc.apply(config: config)
        vc.shouldRecordSession = shouldRecordSession
    }
}
