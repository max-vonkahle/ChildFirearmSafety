//
//  StereoARContainer.swift
//  Child Gun Safety
//
//  Created by Max on 10/5/25.
//


// StereoARContainer.swift
import SwiftUI

struct StereoARContainer: UIViewControllerRepresentable {
    var config = StereoConfig()

    func makeUIViewController(context: Context) -> StereoARViewController {
        StereoARViewController(config: config)
    }

    func updateUIViewController(_ vc: StereoARViewController, context: Context) {
        vc.apply(config: config)
    }
}
