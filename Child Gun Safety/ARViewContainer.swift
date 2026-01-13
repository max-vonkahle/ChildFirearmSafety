//
//  ARViewContainer.swift
//

import SwiftUI
import RealityKit
import ARKit
import UIKit

struct ARViewContainer: UIViewRepresentable {
     @Binding var isArmed: Bool
     @Binding var clearTick: Int
     @Binding var selectedAsset: String?
     var onDisarm: () -> Void

     init(isArmed: Binding<Bool>,
          clearTick: Binding<Int>,
          selectedAssetBinding: Binding<String?>? = nil,
          onDisarm: @escaping () -> Void) {
         _isArmed = isArmed
         _clearTick = clearTick
         if let selectedAssetBinding = selectedAssetBinding {
             _selectedAsset = selectedAssetBinding
         } else {
             _selectedAsset = .constant(nil)
         }
         self.onDisarm = onDisarm
     }

    // Use your existing external coordinator type
    typealias Coordinator = ARCoordinator

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // --- AR configuration ---
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation) {
            config.frameSemantics.insert(.personSegmentation)
        }

        // Optional: mesh occlusion and scene depth if available
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }

        arView.session.run(config)
        arView.debugOptions = []  // Disable debug visualizations like anchor cubes
        arView.session.delegate = context.coordinator

        // Tap gesture forwarding to coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(ARCoordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false  // Add this line to allow touches to propagate
        arView.addGestureRecognizer(tap)

        // Bind coordinator to ARView and preload models
        context.coordinator.bind(arView: arView, onDisarm: onDisarm)
        context.coordinator.preloadModel(named: "gun")
        context.coordinator.preloadModel(named: "table")
        context.coordinator.startFrameUpdates()

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Sync coordinator with SwiftUI state
        context.coordinator.isArmed = isArmed
        context.coordinator.selectedAsset = selectedAsset

        // Trigger clear when clearTick changes
        if context.coordinator.lastClearTick != clearTick {
            context.coordinator.lastClearTick = clearTick
            context.coordinator.clearAsset()
            // Allow future warnings after clearing
            context.coordinator.warningShown = false
        }
    }

    func makeCoordinator() -> Coordinator { ARCoordinator() }
}
