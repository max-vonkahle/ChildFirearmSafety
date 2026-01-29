//
//  ARCoordinator.swift
//  Child Gun Safety
//
//  Created by Max on 9/25/25.
//


//
//  ARCoordinator.swift
//  Child Gun Safety
//
//  Extracted Coordinator that owns AR session logic, hand detection,
//  asset placement, and ARWorldMap save/load.
//  Pair with WorldMapStore.swift
//

import Foundation
import SwiftUI
import RealityKit
import ARKit
import Combine
import Vision
import UIKit

// Notifications to trigger save/load from SwiftUI
extension Notification.Name {
    static let saveWorldMap = Notification.Name("SaveWorldMap")
    static let loadWorldMap = Notification.Name("LoadWorldMap")
    static let assetsConfigured = Notification.Name("AssetsConfigured")
}


final class ARCoordinator: NSObject, ARSessionDelegate {
    // Backrefs
    weak var arView: ARView?
    var onDisarm: (() -> Void)?

    // SwiftUI-mirrored state
    var isArmed: Bool = false
    var lastClearTick: Int = 0
    var selectedAsset: String? = nil

    // Entities / Anchors
    private var modelRoots: [String: Entity] = [:]
    private var placedAnchors: [AnchorEntity] = []
    private var placedARAnchors: [ARAnchor] = []
    private var currentAsset: String? = nil
    private var hasNotifiedAssetsConfigured = false  // Ensure notification fires only once

    // Subscriptions / requests
    private var cancellable: AnyCancellable?
    private var updateSub: Cancellable?
    private let handRequest = VNDetectHumanHandPoseRequest()
    private let handRequestHandler = VNSequenceRequestHandler()

    // Throttle & reach-once flag
    private var lastDecisionAt: CFTimeInterval = 0
    var warningShown: Bool = false
    private var wasNear: Bool = false
    private var lastNearDistance: Float = 0
    private var lastNearTime: CFTimeInterval = 0

    // Tuning knobs
    private let pixelPadding: CGFloat = 24        // expands gun rect in screen px
    private let depthMargin: Float = 0.07         // hand must be this much closer than gun (meters)
    private let decisionInterval: CFTimeInterval = 0.15

    // Prevent overlapping frame processing
    private var isProcessingFrame = false

    // MARK: - Wiring

    func bind(arView: ARView, onDisarm: @escaping () -> Void) {
        self.arView = arView
        self.onDisarm = onDisarm

        // Listen for save/load triggers (roomId provided by SwiftUI views when available)
        NotificationCenter.default.addObserver(forName: .saveWorldMap, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let roomId = (note.userInfo?["roomId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveId: String
            if let roomId, !roomId.isEmpty {
                effectiveId = roomId
            } else {
                effectiveId = "default"
            }
            self.saveWorldMap(roomId: effectiveId)
        }
        NotificationCenter.default.addObserver(forName: .loadWorldMap, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let roomId = (note.userInfo?["roomId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveId: String
            if let roomId, !roomId.isEmpty {
                effectiveId = roomId
            } else {
                effectiveId = "default"
            }
            self.loadWorldMap(roomId: effectiveId)
        }
        // Listen for AR commands (e.g., hide gun)
        NotificationCenter.default.addObserver(forName: .arCommand, object: nil, queue: .main) { [weak self] note in
            guard let self = self else { return }
            let arg = note.userInfo?[BusKey.arg] as? String
            if arg == "setGunVisibility:false" {
                self.setGunVisible(false)
            }
        }
    }

    // MARK: - Model preload (async/await first, iOS 17 fallback)
    func preloadModel(named name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "usdz") else {
            print("Model not found in bundle: \(name).usdz")
            return
        }

        if #available(iOS 18.0, *) {
            Task { @MainActor [weak self] in
                do {
                    let entity = try await Entity(contentsOf: url)
                    self?.modelRoots[name] = entity
                    self?.scaleToFit(entity, targetWidthMeters: 0.18, objectType: name)
                } catch {
                    print("Model load error:", error)
                }
            }
        } else {
            cancellable = Entity.loadAsync(contentsOf: url)
                .receive(on: DispatchQueue.main)
                .sink(receiveCompletion: { comp in
                    if case let .failure(err) = comp { print("Model load error:", err) }
                }, receiveValue: { [weak self] entity in
                    self?.modelRoots[name] = entity
                    self?.scaleToFit(entity, targetWidthMeters: 0.18, objectType: name)
                })
        }
    }

    // MARK: - Per-frame updates
    func startFrameUpdates() {
        guard let arView = arView else { return }
        updateSub = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            self?.onFrame()
        }
    }

    private func onFrame() {
        // Prevent overlapping frame processing
        if isProcessingFrame { return }
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        guard let arView = arView,
              let frame = arView.session.currentFrame,
              !placedAnchors.isEmpty,  // Check if any anchors are placed
              warningShown == false
        else { return }

        // Throttle
        let t = CACurrentMediaTime()
        if t - lastDecisionAt < decisionInterval { return }
        lastDecisionAt = t

        autoreleasepool {
            // --- Proximity & back-away detection
            if let d = gunDistanceFromCamera(frame: frame) {
                let tNow = t
                // Enter near zone once
                if d < 1.0, wasNear == false {
                    wasNear = true
                    lastNearDistance = d
                    lastNearTime = tNow
                    NotificationCenter.default.post(name: .arEvent, object: nil,
                        userInfo: [BusKey.arevent: AREvent.gunProximityNear(distance: d)])
                }
                // Detect backing away within a short window
                if wasNear, d - lastNearDistance > 0.7, tNow - lastNearTime < 3.0 {
                    wasNear = false
                    NotificationCenter.default.post(name: .arEvent, object: nil,
                        userInfo: [BusKey.arevent: AREvent.childBacksAway(delta: d - lastNearDistance)])
                }
                // Update running minimum distance while in near state
                if wasNear { lastNearDistance = min(lastNearDistance, d) }
            }

            // Vision hand pose
            do {
                try handRequestHandler.perform([handRequest],
                                               on: frame.capturedImage,
                                               orientation: currentImageOrientation())
            } catch {
                return
            }

            guard let observations = handRequest.results, !observations.isEmpty else { return }
            guard let gunRect = gunScreenRect() else { return }

            // Check hands against gun rect + depth
            for hand in observations {
                let pts = (try? hand.recognizedPoints(.all)) ?? [:]
                // fingertips first, then wrist
                for key in [VNHumanHandPoseObservation.JointName.indexTip,
                            .middleTip, .wrist] {
                    guard let rp = pts[key], rp.confidence > 0.35 else { continue }
                    let hp = visionNormToScreen(rp.location)

                    // 1) inside/near the gun’s screen footprint?
                    guard gunRect.contains(hp) else { continue }

                    // 2) hand closer than gun?
                    if let depthBuf = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap,
                       let handZ = sampleDepthAtScreen(depthBuf, screenPoint: hp),
                       let gunZ = gunDistanceFromCamera(frame: frame),
                       handZ + depthMargin < gunZ {

                        warningShown = true
                        setGunVisible(false)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        NotificationCenter.default.post(name: .arEvent, object: nil, userInfo: [BusKey.arevent: AREvent.reachGesture])
                        return
                    }
                }
            }
        }
    }

    // MARK: - Tap to place or move (only when armed)
    @objc func handleTap(_ sender: UITapGestureRecognizer) {
        guard let arView = arView else { return }
        if !isArmed {
            // If tapping near gun while unarmed, treat as reach proxy
            if let rect = gunScreenRect(), rect.contains(sender.location(in: arView)) {
                NotificationCenter.default.post(name: .arEvent, object: nil, userInfo: [BusKey.arevent: AREvent.reachGesture])
            }
            return
        }

        let location = sender.location(in: arView)

        // Try to hit test against entities first (like table tops)
        var targetTransform: simd_float4x4?

        // Cast ray against all entities with collision shapes
        let hitResults = arView.hitTest(location, query: .nearest)
        if let result = hitResults.first {
            // We hit an entity - create transform at the hit position
            let hitPosition = result.position

            // Create a transform matrix at the hit position, maintaining world up orientation
            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4<Float>(hitPosition.x, hitPosition.y, hitPosition.z, 1.0)

            targetTransform = transform
        }

        // If we didn't hit an entity, try ARKit plane detection
        if targetTransform == nil {
            let planeQuery = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .horizontal)
            if let ray = planeQuery.first {
                targetTransform = ray.worldTransform
            }
        }

        guard let transform = targetTransform else {
            return
        }

        // Place new asset
        let asset = selectedAsset ?? "gun"
        if let root = modelRoots[asset]?.clone(recursive: true) {
            layFlat(root, objectType: asset)
            root.position = [0, 0.01, 0]

            // Enable collision for tables so other objects can be placed on them
            if asset == "table" {
                root.generateCollisionShapes(recursive: true)
            }

            let entityAnchor = AnchorEntity(world: transform)
            entityAnchor.addChild(root)
            arView.scene.addAnchor(entityAnchor)
            placedAnchors.append(entityAnchor)

            // Create the ARAnchor that will be serialized into the world map
            let arAnchor = ARAnchor(name: "placedAsset_\(asset)", transform: transform)
            arView.session.add(anchor: arAnchor)
            placedARAnchors.append(arAnchor)

            warningShown = false
            isArmed = false
            onDisarm?()
        }
    }

    // MARK: - ARWorldMap Save / Load

    func saveWorldMap(roomId: String) {
        guard let arView = arView, let frame = arView.session.currentFrame else { return }

        let status = frame.worldMappingStatus
        guard status == .mapped || status == .extending else {
            print("World map not ready (status: \(status)). Walk around more.")
            return
        }

        arView.session.getCurrentWorldMap { map, error in
            if let error = error { print("getCurrentWorldMap error:", error); return }
            guard let map = map else { print("No world map"); return }
            do {
                try WorldMapStore.save(map, roomId: roomId)
                print("Saved map for \(roomId)")
            } catch {
                print("Save map failed:", error)
            }
        }
    }

    func loadWorldMap(roomId: String) {
        guard let arView = arView else { return }

        // Reset notification flag for new room
        hasNotifiedAssetsConfigured = false

        do {
            let map = try WorldMapStore.load(roomId: roomId)
            let cfg = ARWorldTrackingConfiguration()
            cfg.planeDetection = [.horizontal]

            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                cfg.sceneReconstruction = .mesh
                arView.environment.sceneUnderstanding.options.insert(.occlusion)
            }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                cfg.frameSemantics.insert(.sceneDepth)
            }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                cfg.frameSemantics.insert(.personSegmentationWithDepth)
            } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation) {
                cfg.frameSemantics.insert(.personSegmentation)
            }

            cfg.initialWorldMap = map
            arView.session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
            // Anchors (incl. our named one) will appear in session(_:didAdd:)
            print("Loaded map for \(roomId). Ask user to scan to relocalize.")
        } catch {
            print("Load map failed:", error)
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard let arView = arView else { return }
        var restoredAnyAsset = false

        for a in anchors where a.name?.hasPrefix("placedAsset_") == true {
            // Parse asset type
            let components = a.name?.split(separator: "_") ?? []
            let asset = components.count > 1 ? String(components[1]) : "gun"

            // Add to our tracked AR anchors
            placedARAnchors.append(a)

            // Spawn the model at the saved transform
            if let model = modelRoots[asset]?.clone(recursive: true) {
                layFlat(model, objectType: asset)
                model.position = [0, 0.01, 0]

                // Enable collision for tables so other objects can be placed on them
                if asset == "table" {
                    model.generateCollisionShapes(recursive: true)
                }

                let entityAnchor = AnchorEntity(world: a.transform)
                entityAnchor.addChild(model)
                arView.scene.addAnchor(entityAnchor)
                placedAnchors.append(entityAnchor)

                // Allow future warnings again
                warningShown = false

                print("Restored \(asset) at saved position")
                restoredAnyAsset = true
            }
        }

        // Only notify after ALL anchors in this batch are restored
        // Add delay to ensure assets are fully rendered/visible
        if restoredAnyAsset && !hasNotifiedAssetsConfigured {
            hasNotifiedAssetsConfigured = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                print("✅ All assets restored and visible, notifying UI")
                NotificationCenter.default.post(name: .assetsConfigured, object: nil)
            }
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        // Hook for showing/hiding a "Scan to align room" overlay if you want.
        if case .normal = camera.trackingState {
            // Tracking stabilized
        }
    }

    // MARK: - Helpers

    /// Rotate −90° around Z so the model lies on a horizontal surface.
    func layFlat(_ e: Entity, objectType: String? = nil) {
        // Skip laying flat for the table
        if objectType == "table" {
            return
        }
        
        // Gun needs different rotation
        if objectType == "gun" {
            let q = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))  // Rotate around Z
            e.orientation = q * e.orientation
        } else {
            let q = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
            e.orientation = q * e.orientation
        }
    }

    func scaleToFit(_ entity: Entity?, targetWidthMeters: Float = 0.18, objectType: String) {
        guard let e = entity else { return }
        let b = e.visualBounds(relativeTo: nil)
        let size = b.extents
        let currentWidth = max(size.x, size.z)
        guard currentWidth > 0 else { return }
        
        // Use different target sizes for different objects
        let targetSize: Float
        if objectType == "table" {
            targetSize = 1.0 // Larger size for tables
        } else {
            targetSize = targetWidthMeters // Default size for other objects
        }
        
        let factor = targetSize / currentWidth
        e.scale *= SIMD3<Float>(repeating: factor)
    }


    /// Compute the gun's screen-space bounding rect (with padding).
    /// Only looks for gun anchors (not tables or other objects).
    func gunScreenRect() -> CGRect? {
        guard let arView = arView else { return nil }

        // Find the first gun anchor (check AR anchors to get the asset type)
        guard let gunIndex = placedARAnchors.firstIndex(where: { $0.name?.contains("_gun") == true }),
              gunIndex < placedAnchors.count else { return nil }

        let anchor = placedAnchors[gunIndex]
        guard let model = anchor.children.first else { return nil }

        let b = model.visualBounds(relativeTo: nil)
        let c = b.center
        let e = b.extents / 2
        let corners: [SIMD3<Float>] = [
            [c.x - e.x, c.y - e.y, c.z - e.z],
            [c.x + e.x, c.y - e.y, c.z - e.z],
            [c.x - e.x, c.y + e.y, c.z - e.z],
            [c.x + e.x, c.y + e.y, c.z - e.z],
            [c.x - e.x, c.y - e.y, c.z + e.z],
            [c.x + e.x, c.y - e.y, c.z + e.z],
            [c.x - e.x, c.y + e.y, c.z + e.z],
            [c.x + e.x, c.y + e.y, c.z + e.z],
        ]
        let pts = corners.compactMap { arView.project($0) }
        guard pts.count >= 2 else { return nil }

        var minX = CGFloat.greatestFiniteMagnitude, minY = minX
        var maxX: CGFloat = 0, maxY: CGFloat = 0
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        var rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        rect = rect.insetBy(dx: -pixelPadding, dy: -pixelPadding)
        return rect
    }

    func projectedGunScreenPoint() -> CGPoint? {
        guard let arView = arView else { return nil }

        // Find the first gun anchor
        guard let gunIndex = placedARAnchors.firstIndex(where: { $0.name?.contains("_gun") == true }),
              gunIndex < placedAnchors.count else { return nil }

        let anchor = placedAnchors[gunIndex]
        guard let model = anchor.children.first else { return nil }
        let bounds = model.visualBounds(relativeTo: nil)
        let centerWorld = bounds.center
        return arView.project(centerWorld)
    }

    func visionNormToScreen(_ loc: CGPoint) -> CGPoint {
        guard let arView = arView else { return .zero }
        let size = arView.bounds.size
        let x = loc.x * size.width
        let y = (1.0 - loc.y) * size.height // Vision origin is bottom-left
        return CGPoint(x: x, y: y)
    }

    func sampleDepthAtScreen(_ depthBuf: CVPixelBuffer, screenPoint: CGPoint) -> Float? {
        guard let arView = arView else { return nil }
        let dmW = CVPixelBufferGetWidth(depthBuf)
        let dmH = CVPixelBufferGetHeight(depthBuf)
        let u = Int(round(CGFloat(dmW) * (screenPoint.x / arView.bounds.width)))
        let v = Int(round(CGFloat(dmH) * (screenPoint.y / arView.bounds.height)))
        return sampleDepth(buffer: depthBuf, u: u, v: v)
    }

    func gunDistanceFromCamera(frame: ARFrame) -> Float? {
        // Find the first gun anchor
        guard let gunIndex = placedARAnchors.firstIndex(where: { $0.name?.contains("_gun") == true }),
              gunIndex < placedAnchors.count else { return nil }

        let anchor = placedAnchors[gunIndex]
        guard let model = anchor.children.first else { return nil }
        let world = model.position(relativeTo: nil)
        let cam = frame.camera.transform
        let rel = cam.inverse * SIMD4<Float>(world.x, world.y, world.z, 1)
        return abs(rel.z)
    }

    func sampleDepth(buffer: CVPixelBuffer, u: Int, v: Int) -> Float? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard u >= 0, u < w, v >= 0, v < h else { return nil }

        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: Float32.self)
        let rowStride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float32>.size
        let depth = base[v * rowStride + u]
        return depth.isFinite && depth > 0 ? depth : nil
    }

    func hideGunAndShowMessage() {
        setGunVisible(false)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func setGunVisible(_ visible: Bool) {
        if visible { return } // v1 only supports hiding; showing would require re-anchoring

        // Find and remove only gun anchors
        var indicesToRemove: [Int] = []
        for (index, arAnchor) in placedARAnchors.enumerated() {
            if arAnchor.name?.contains("_gun") == true {
                indicesToRemove.append(index)
            }
        }

        // Remove in reverse order to maintain correct indices
        for index in indicesToRemove.reversed() {
            if index < placedAnchors.count {
                arView?.scene.removeAnchor(placedAnchors[index])
                placedAnchors.remove(at: index)
            }
            if index < placedARAnchors.count {
                arView?.session.remove(anchor: placedARAnchors[index])
                placedARAnchors.remove(at: index)
            }
        }

        warningShown = false
    }

    func currentImageOrientation() -> CGImagePropertyOrientation {
        guard let io = arView?.window?.windowScene?.interfaceOrientation else { return .right }
        switch io {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        default: return .right
        }
    }

    func clearAsset() {
        // Remove all visual anchors
        for anchor in placedAnchors {
            arView?.scene.removeAnchor(anchor)
        }
        placedAnchors.removeAll()

        // Remove all AR anchors
        for ar in placedARAnchors {
            arView?.session.remove(anchor: ar)
        }
        placedARAnchors.removeAll()

        currentAsset = nil
    }
}
