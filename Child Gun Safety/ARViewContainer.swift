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
    var onDisarm: () -> Void

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
        arView.session.delegate = context.coordinator

        // Tap gesture forwarding to coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(ARCoordinator.handleTap(_:)))
        arView.addGestureRecognizer(tap)

        // Bind coordinator to ARView and preload model
        context.coordinator.bind(arView: arView, onDisarm: onDisarm)
        context.coordinator.preloadModel(named: "gun")
        context.coordinator.startFrameUpdates()

        // Notifications (Save / Load world map) — roomId in userInfo["roomId"]
        NotificationCenter.default.addObserver(
            forName: .saveWorldMap, object: nil, queue: .main
        ) { [weak coord = context.coordinator] note in
            guard let roomId = note.userInfo?["roomId"] as? String else { return }
            coord?.saveWorldMap(roomId: roomId)
        }
        NotificationCenter.default.addObserver(
            forName: .loadWorldMap, object: nil, queue: .main
        ) { [weak coord = context.coordinator] note in
            guard let roomId = note.userInfo?["roomId"] as? String else { return }
            coord?.loadWorldMap(roomId: roomId)
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Sync coordinator with SwiftUI state
        context.coordinator.isArmed = isArmed

        // Trigger clear when clearTick changes
        if context.coordinator.lastClearTick != clearTick {
            context.coordinator.lastClearTick = clearTick
            context.coordinator.clearGun()
            // Allow future warnings after clearing
            context.coordinator.warningShown = false
        }
    }

    func makeCoordinator() -> Coordinator { ARCoordinator() }
}
