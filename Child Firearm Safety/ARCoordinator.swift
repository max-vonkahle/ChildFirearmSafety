//
//  ARCoordinator.swift
//  Child Firearm Safety
//
//  Created by Max on 9/25/25.
//


//
//  ARCoordinator.swift
//  Child Firearm Safety
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
    private var savedGunAnchors: [(visual: AnchorEntity, ar: ARAnchor)] = []
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

    // Frame-based deduplication for reach gestures
    private var lastReachGestureFrame: Int = 0  // Track which frame posted reach gesture
    private var currentFrameNumber: Int = 0      // Increment each frame

    // Reset instruction state
    private var isWaitingForResetSpeech: Bool = false  // Don't allow taps until speech completes

    // Tuning knobs
    private let pixelPadding: CGFloat = 24        // expands gun rect in screen px
    private let depthMargin: Float = 0.07         // hand must be this much closer than gun (meters)
    private let decisionInterval: CFTimeInterval = 0.15
    private let runAwayThreshold: Float = 1.5       // Must retreat 1.5m+ to count as "running"
    private let runAwayMaxTime: CFTimeInterval = 2.0 // Must do it within 2 seconds
    private let backAwayThreshold: Float = 0.7      // Backing away threshold (existing behavior)
    private let backAwayMaxTime: CFTimeInterval = 3.0 // Backing away time window

    // Prevent overlapping frame processing
    private var isProcessingFrame = false

    // Frame timing diagnostics
    private var lastFrameTime: CFTimeInterval = 0
    private var frameGapThreshold: CFTimeInterval = 0.1  // Log if gap > 100ms

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
        // Listen for AR commands (e.g., hide/show gun)
        NotificationCenter.default.addObserver(forName: .arCommand, object: nil, queue: .main) { [weak self] note in
            guard let self = self else { return }
            let arg = note.userInfo?[BusKey.arg] as? String
            // print("🔫 [AR] Received AR command: \(arg ?? "nil")")
            if arg == "setGunVisibility:false" {
                self.setGunVisible(false)
            } else if arg == "setGunVisibility:true" {
                self.setGunVisible(true)
            } else if arg == "disableTapDuringSpeech" {
                // print("🔇 [AR] Disabling tap (model speaking reset instruction)")
                self.isWaitingForResetSpeech = true
            } else if arg == "enableTapAfterSpeech" {
                // print("🔊 [AR] Enabling tap (model finished speaking)")
                self.isWaitingForResetSpeech = false
            }
        }
    }

    // MARK: - Model preload (async/await first, iOS 17 fallback)
    func preloadModel(named name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "usdz") else {
            // print("Model not found in bundle: \(name).usdz")
            return
        }

        if #available(iOS 18.0, *) {
            Task { @MainActor [weak self] in
                do {
                    let entity = try await Entity(contentsOf: url)
                    self?.modelRoots[name] = entity
                    self?.scaleToFit(entity, targetWidthMeters: 0.18, objectType: name)
                } catch {
                    // print("Model load error:", error)
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
        // Frame timing diagnostics - detect frame drops
        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let gap = now - lastFrameTime
            if gap > frameGapThreshold {
                print("⚠️ [ARCoord] Frame gap: \(Int(gap * 1000))ms")
            }
        }
        lastFrameTime = now

        // Prevent overlapping frame processing
        if isProcessingFrame { return }
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        // Increment frame counter
        currentFrameNumber += 1

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
                    NotificationCenter.default.post(name: .arTrainingEvent, object: nil,
                        userInfo: [BusKey.arevent: AREvent.gunProximityNear(distance: d)])
                }
                // Detect running away or backing away
                let elapsedTime = tNow - lastNearTime
                let retreatDistance = d - lastNearDistance

                // Check for running away first (greater distance, less time)
                if wasNear, retreatDistance > runAwayThreshold, elapsedTime < runAwayMaxTime {
                    wasNear = false
                    NotificationCenter.default.post(name: .arTrainingEvent, object: nil,
                        userInfo: [BusKey.arevent: AREvent.childRunsAway(delta: retreatDistance, duration: elapsedTime)])
                }
                // Fall back to backing away (existing behavior)
                else if wasNear, retreatDistance > backAwayThreshold, elapsedTime < backAwayMaxTime {
                    wasNear = false
                    NotificationCenter.default.post(name: .arTrainingEvent, object: nil,
                        userInfo: [BusKey.arevent: AREvent.childBacksAway(delta: retreatDistance)])
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

                        // Extra safety: prevent duplicate events in same frame (multiple hands)
                        guard currentFrameNumber != lastReachGestureFrame else {
                            print("⏭️ [AR] Reach gesture already posted in frame \(currentFrameNumber), skipping additional hand")
                            continue
                        }
                        lastReachGestureFrame = currentFrameNumber

                        warningShown = true
                        setGunVisible(false)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        NotificationCenter.default.post(name: .arTrainingEvent, object: nil, userInfo: [BusKey.arevent: AREvent.reachGesture])
                        return
                    }
                }
            }
        }
    }

    // MARK: - Tap gesture handler
    @objc func handleTap(_ sender: UITapGestureRecognizer) {
        print("👆 [AR] TAP DETECTED - warningShown: \(warningShown), isArmed: \(isArmed), savedGunAnchors: \(savedGunAnchors.count), waitingForSpeech: \(isWaitingForResetSpeech)")

        guard let arView = arView else {
            print("❌ [AR] No arView, ignoring tap")
            return
        }

        // If gun is hidden (warningShown), user is tapping to confirm reset
        if warningShown {
            // Check if we're still waiting for reset instruction speech to complete
            if isWaitingForResetSpeech {
                print("⏭️ [AR] Tap ignored - waiting for model to finish speaking")
                return
            }

            print("✅ [AR] User tapped to confirm reset - posting userTappedToReset event")
            NotificationCenter.default.post(name: .arTrainingEvent, object: nil, userInfo: [BusKey.arevent: AREvent.userTappedToReset])
            return
        }

        // Only allow taps when armed for asset placement
        guard isArmed else {
            print("⏭️ [AR] Tap ignored - not armed and warningShown is false")
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
        guard let arView = arView, let frame = arView.session.currentFrame else {
            print("❌ Cannot save: AR view or frame not available")
            showSaveAlert(success: false, message: "AR session not ready")
            return
        }

        let status = frame.worldMappingStatus
        print("🗺️ World mapping status: \(status)")

        guard status == .mapped || status == .extending else {
            print("❌ World map not ready (status: \(status)). Walk around more.")
            showSaveAlert(success: false, message: "Please walk around more to map the environment.\n\nMapping status: \(statusDescription(status))")
            return
        }

        print("✅ World mapping status OK, getting world map...")
        arView.session.getCurrentWorldMap { [weak self] map, error in
            if let error = error {
                print("❌ getCurrentWorldMap error:", error)
                self?.showSaveAlert(success: false, message: "Failed to get world map: \(error.localizedDescription)")
                return
            }
            guard let map = map else {
                print("❌ No world map returned")
                self?.showSaveAlert(success: false, message: "No world map data available")
                return
            }
            do {
                try WorldMapStore.save(map, roomId: roomId)
                print("✅ Saved map for '\(roomId)' (\(map.anchors.count) anchors)")
                self?.showSaveAlert(success: true, message: "Room '\(roomId)' saved successfully!")
            } catch {
                print("❌ Save map failed:", error)
                self?.showSaveAlert(success: false, message: "Failed to save: \(error.localizedDescription)")
            }
        }
    }

    private func statusDescription(_ status: ARFrame.WorldMappingStatus) -> String {
        switch status {
        case .notAvailable: return "Not Available"
        case .limited: return "Limited"
        case .extending: return "Extending"
        case .mapped: return "Mapped"
        @unknown default: return "Unknown"
        }
    }

    private func showSaveAlert(success: Bool, message: String) {
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootViewController = windowScene.windows.first?.rootViewController else {
                return
            }

            let alert = UIAlertController(
                title: success ? "Save Successful" : "Save Failed",
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))

            // Find the topmost presented view controller
            var topController = rootViewController
            while let presented = topController.presentedViewController {
                topController = presented
            }

            topController.present(alert, animated: true)
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

                // Handle gun restoration specially during reset mode
                if asset == "gun" && !savedGunAnchors.isEmpty {
                    print("⚠️ [AR] Gun anchor restored during relocalization, but gun should stay hidden (in reset mode)")
                    // Remove the anchor we just added - gun should stay hidden
                    arView.scene.removeAnchor(entityAnchor)
                    if let last = placedAnchors.last {
                        placedAnchors.removeLast()
                    }
                } else {
                    print("Restored \(asset) at saved position")
                    restoredAnyAsset = true

                    // Only reset warningShown if gun is not currently hidden
                    // Don't reset during reset mode (when savedGunAnchors has items)
                    if savedGunAnchors.isEmpty {
                        warningShown = false
                    }
                }
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
        print("🔫 [AR] setGunVisible(\(visible)) called - current warningShown: \(warningShown)")

        if visible {
            // Show gun - restore from saved anchors
            print("🔫 [AR] Attempting to show gun. Saved anchors count: \(savedGunAnchors.count)")
            guard let arView = arView, !savedGunAnchors.isEmpty else {
                print("🔫 [AR] ⚠️ Cannot show gun: arView=\(arView != nil), savedAnchors empty=\(savedGunAnchors.isEmpty)")
                return
            }

            for saved in savedGunAnchors {
                let pos = saved.ar.transform.columns.3
                print("🔫 [AR] Restoring gun at position: (\(pos.x), \(pos.y), \(pos.z))")

                // Re-add visual anchor to scene
                arView.scene.addAnchor(saved.visual)
                placedAnchors.append(saved.visual)

                // Re-add AR anchor to session
                arView.session.add(anchor: saved.ar)
                placedARAnchors.append(saved.ar)
            }

            // Clear saved anchors
            savedGunAnchors.removeAll()
            warningShown = false
            lastReachGestureFrame = 0  // Allow detection on next encounter
            print("🔫 [AR] ✅ Gun restored to scene - warningShown now: \(warningShown)")
            return
        }

        // Hide gun - save anchors before removing
        print("🔫 [AR] Hiding gun...")
        var indicesToRemove: [Int] = []

        // Find gun anchors
        for (index, arAnchor) in placedARAnchors.enumerated() {
            if arAnchor.name?.contains("_gun") == true {
                indicesToRemove.append(index)
            }
        }

        print("🔫 [AR] Found \(indicesToRemove.count) gun anchors to hide")

        // Only proceed if there are gun anchors to hide
        guard !indicesToRemove.isEmpty else {
            print("🔫 [AR] ⚠️ No gun anchors to hide (already hidden?). Keeping \(savedGunAnchors.count) saved anchors intact.")
            return
        }

        // Clear saved anchors only when we have new ones to save
        savedGunAnchors.removeAll()

        // Save and remove in reverse order to maintain correct indices
        for index in indicesToRemove.reversed() {
            if index < placedAnchors.count && index < placedARAnchors.count {
                // Save before removing
                savedGunAnchors.append((visual: placedAnchors[index], ar: placedARAnchors[index]))

                // Remove from scene and session
                arView?.scene.removeAnchor(placedAnchors[index])
                arView?.session.remove(anchor: placedARAnchors[index])

                // Remove from tracking arrays
                placedAnchors.remove(at: index)
                placedARAnchors.remove(at: index)
            }
        }

        print("🔫 [AR] ✅ Gun hidden. Saved \(savedGunAnchors.count) anchors for later restoration")
        warningShown = true  // Set to true so taps will be detected for reset
        print("🔫 [AR] warningShown set to TRUE (gun is hidden, waiting for tap)")
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
