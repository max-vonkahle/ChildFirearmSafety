//
//  ARCoordinator.swift
//  Child Firearm Safety
//
//  Created by Max on 9/25/25.
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
    private var startMarkerAnchor: AnchorEntity? = nil  // Start position floor marker
    private var startMarkerARAnch: ARAnchor? = nil
    private var startMarkerWorldPosition: SIMD3<Float>? = nil
    private var currentAsset: String? = nil
    private var hasNotifiedAssetsConfigured = false  // Ensure notification fires only once

    // Subscriptions / requests
    private var cancellable: AnyCancellable?
    private var updateSub: Cancellable?
    private let handRequest = VNDetectHumanHandPoseRequest()
    private let handRequestHandler = VNSequenceRequestHandler()

    // Background Vision processing
    private let visionQueue = DispatchQueue(label: "com.childgunsafety.vision", qos: .userInitiated)
    private var cachedHandObservations: [VNHumanHandPoseObservation] = []
    private let observationsLock = NSLock()
    private var isVisionProcessing = false

    // Throttle & reach-once flag
    private var lastDecisionAt: CFTimeInterval = 0
    var warningShown: Bool = false
    private var lastMappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    private var wasNear: Bool = false
    private var lastNearDistance: Float = 0
    private var lastNearTime: CFTimeInterval = 0

    // Track when retreat motion actually begins
    private var isRetreating: Bool = false
    private var retreatStartDistance: Float = 0
    private var retreatStartTime: CFTimeInterval = 0
    private let retreatStartThreshold: Float = 0.15  // Movement of 15cm triggers "retreat started"

    // Frame-based deduplication for reach gestures
    private var lastReachGestureFrame: Int = 0  // Track which frame posted reach gesture
    private var currentFrameNumber: Int = 0      // Increment each frame

    // Reset instruction state
    private var isWaitingForResetSpeech: Bool = false  // Don't allow taps until speech completes
    private var isWaitingForStartMarker: Bool = false  // Don't allow taps until child walks to red X
    private var isWaitingForActOutStart: Bool = false  // Phase 2 begins only after marker + tap
    private var isEncounterDetectionEnabled: Bool = false

    // Tuning knobs
    private let pixelPadding: CGFloat = 24        // expands gun rect in screen px
    private let depthMargin: Float = 0.07         // hand must be this much closer than gun (meters)
    private let maxReachDistance: Float = 0.25    // hand must be within 0.25m of gun depth to count as reaching
    private let decisionInterval: CFTimeInterval = 0.15
    private let runAwayThreshold: Float = 1.5       // Must retreat 1.5m+ to count as "running"
    private let runAwayMaxTime: CFTimeInterval = 2.0 // Must do it within 2 seconds
    private let markerReachDistance: Float = 0.5     // Must get within 0.5m of the red marker

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
        // Listen for start marker placement / removal
        NotificationCenter.default.addObserver(forName: .placeStartMarker, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.placeStartMarkerAtDevicePosition()
        }
        NotificationCenter.default.addObserver(forName: .clearStartMarker, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.clearStartMarker()
        }

        // Clear marker gate when child reaches the start marker
        NotificationCenter.default.addObserver(forName: .arTrainingEvent, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let e = note.userInfo?[BusKey.arevent] as? AREvent,
                  case .childAtStartMarker = e else { return }
            self.isWaitingForStartMarker = false
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
            } else if arg == "prepareActOutStart" {
                print("📍 [AR] prepareActOutStart received")
                self.setStartMarkerVisible(true)
                self.isWaitingForActOutStart = true
                self.isWaitingForStartMarker = true
                self.isEncounterDetectionEnabled = false
                self.wasNear = false
                self.isRetreating = false
            } else if arg == "showStartMarker" {
                self.setStartMarkerVisible(true)
                // If gun is hidden (reset scenario), block tap until child walks to marker
                if self.warningShown {
                    self.isWaitingForStartMarker = true
                }
            } else if arg == "hideStartMarker" {
                self.setStartMarkerVisible(false)
                self.isWaitingForStartMarker = false
                self.isWaitingForActOutStart = false
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
              let frame = arView.session.currentFrame
        else { return }

        if startMarkerAnchor?.isEnabled == true,
           isWaitingForStartMarker,
           let xzDist = startMarkerDistanceFromCamera(frame: frame),
           xzDist <= markerReachDistance {
            isWaitingForStartMarker = false
            NotificationCenter.default.post(name: .arTrainingEvent, object: nil,
                userInfo: [BusKey.arevent: AREvent.childAtStartMarker])
        }

        guard !placedAnchors.isEmpty, warningShown == false else { return }

        // Throttle
        let t = CACurrentMediaTime()
        if t - lastDecisionAt < decisionInterval { return }
        lastDecisionAt = t

        autoreleasepool {
            // --- Proximity & back-away detection
            if isEncounterDetectionEnabled, let d = gunDistanceFromCamera(frame: frame) {
                let tNow = t

                // Enter near zone once
                if d < 1.0, wasNear == false {
                    wasNear = true
                    lastNearDistance = d
                    lastNearTime = tNow
                    isRetreating = false  // Reset retreat tracking
                    print("📍 [AR-Retreat] Entered near zone at d=\(String(format: "%.2f", d))m — posting gunProximityNear")
                    NotificationCenter.default.post(name: .arTrainingEvent, object: nil,
                        userInfo: [BusKey.arevent: AREvent.gunProximityNear(distance: d)])
                }

                if wasNear {
                    // Track retreat start - when they begin moving away
                    let distanceFromNearest = d - lastNearDistance

                    if !isRetreating && distanceFromNearest > retreatStartThreshold {
                        // Retreat motion has begun!
                        isRetreating = true
                        retreatStartDistance = d
                        retreatStartTime = tNow
                        print("📍 [AR-Retreat] Retreat started at d=\(String(format: "%.2f", d))m")
                    }

                    if isRetreating {
                        // Measure from when retreat started, not from proximity trigger
                        let retreatElapsed = tNow - retreatStartTime
                        let retreatDistance = d - lastNearDistance

                        // Check for running away (greater distance, less time)
                        if retreatDistance > runAwayThreshold, retreatElapsed < runAwayMaxTime {
                            wasNear = false
                            isRetreating = false
                            print("🏃 [AR-Retreat] childRunsAway fired! delta=\(String(format: "%.2f", retreatDistance))m in \(String(format: "%.2f", retreatElapsed))s")
                            NotificationCenter.default.post(name: .arTrainingEvent, object: nil,
                                userInfo: [BusKey.arevent: AREvent.childRunsAway(delta: retreatDistance, duration: retreatElapsed)])
                        }
                    }

                    // Update running minimum distance while in near state (for retreat start detection)
                    let previousNearDistance = lastNearDistance
                    lastNearDistance = min(lastNearDistance, d)
                    if lastNearDistance < previousNearDistance && isRetreating {
                        print("📍 [AR-Retreat] User returned closer (d=\(String(format: "%.2f", d))m) — resetting retreat timer")
                        isRetreating = false
                    }
                }
            }

            // Dispatch Vision hand pose to background queue (non-blocking)
            if !isVisionProcessing {
                isVisionProcessing = true
                let capturedImage = frame.capturedImage
                let orientation = currentImageOrientation()
                visionQueue.async { [weak self] in
                    guard let self = self else { return }
                    let visionStart = CACurrentMediaTime()
                    do {
                        try self.handRequestHandler.perform([self.handRequest],
                                                            on: capturedImage,
                                                            orientation: orientation)
                    } catch {
                        self.isVisionProcessing = false
                        return
                    }
                    let visionMs = Int((CACurrentMediaTime() - visionStart) * 1000)
                    if visionMs > 16 {
                        print("⚠️ [Vision-BG] Hand pose: \(visionMs)ms")
                    }

                    // Cache observations thread-safely
                    let results = self.handRequest.results ?? []
                    self.observationsLock.lock()
                    self.cachedHandObservations = results
                    self.observationsLock.unlock()
                    self.isVisionProcessing = false
                }
            }

            // Use cached observations for decision making (fast, main thread)
            observationsLock.lock()
            let observations = cachedHandObservations
            observationsLock.unlock()

            guard !observations.isEmpty else { return }
            guard let gunRect = gunScreenRect() else { return }

            // Check hands against gun rect + depth
            var handCheckCount = 0
            for hand in observations {
                let pts = (try? hand.recognizedPoints(.all)) ?? [:]
                // fingertips first, then wrist
                for key in [VNHumanHandPoseObservation.JointName.indexTip,
                            .middleTip, .wrist] {
                    guard let rp = pts[key], rp.confidence > 0.35 else { continue }
                    let hp = visionNormToScreen(rp.location)
                    handCheckCount += 1

                    if currentFrameNumber % 30 == 0 && handCheckCount <= 2 {
                        print("🖐️ [Debug] Vision raw: \(rp.location) → Screen: \(hp)")
                        print("   Gun rect: \(gunRect)")
                        print("   Contains: \(gunRect.contains(hp))")
                    }

                    // 1) inside/near the gun's screen footprint?
                    guard gunRect.contains(hp) else {
                        if currentFrameNumber % 120 == 0 && handCheckCount == 1 {
                            print("📍 [AR-Gesture] Hand at \(hp) outside gun rect \(gunRect)")
                        }
                        continue
                    }

                    print("✋ [AR-Gesture] Hand INSIDE gun rect! Point: \(hp)")
                    print("⚠️ [Debug] HAND INSIDE GUN RECT!")
                    print("   Vision coords: \(rp.location)")
                    print("   Screen coords: \(hp)")
                    print("   Gun rect: \(gunRect)")

                    // 2) hand closer than gun AND within reach distance?
                    if let depthBuf = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap,
                       let handZ = sampleDepthAtScreen(depthBuf, screenPoint: hp),
                       let gunZ = gunDistanceFromCamera(frame: frame) {

                        print("📏 [AR-Gesture] Depth check: handZ=\(handZ), gunZ=\(gunZ), margin=\(depthMargin), maxReach=\(maxReachDistance)")
                        
                        // Hand must be:
                        // 1. Closer than gun (handZ + margin < gunZ)
                        // 2. Within maxReachDistance of gun (gunZ - handZ < maxReachDistance)
                        // This prevents false positives when hand is just in front of camera
                        let isCloserThanGun = handZ + depthMargin < gunZ
                        let isWithinReachDistance = gunZ - handZ < maxReachDistance
                        
                        guard isCloserThanGun && isWithinReachDistance else {
                            if currentFrameNumber % 60 == 0 {
                                print("⚠️ [AR-Gesture] Depth gate rejected hand: closerThanGun=\(isCloserThanGun) withinReach=\(isWithinReachDistance)")
                            }
                            continue
                        }

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
        print("👆 [AR] TAP DETECTED - warningShown: \(warningShown), waitingForActOutStart: \(isWaitingForActOutStart), isArmed: \(isArmed), savedGunAnchors: \(savedGunAnchors.count), waitingForSpeech: \(isWaitingForResetSpeech)")

        guard let arView = arView else {
            print("❌ [AR] No arView, ignoring tap")
            return
        }

        if isWaitingForActOutStart {
            if isWaitingForResetSpeech {
                print("⏭️ [AR] Tap ignored - waiting for model to finish act-out instructions")
                return
            }
            if isWaitingForStartMarker {
                if let frame = arView.session.currentFrame,
                   let dist = startMarkerDistanceFromCamera(frame: frame) {
                    print("⏭️ [AR] Tap ignored - \(String(format: "%.2f", dist))m from marker (need ≤\(markerReachDistance)m)")
                } else {
                    print("⏭️ [AR] Tap ignored - child hasn't reached the start marker yet (position unavailable)")
                }
                return
            }

            print("✅ [AR] User tapped to begin act-out - posting userTappedToBeginActOut event")
            isWaitingForActOutStart = false
            isEncounterDetectionEnabled = true
            wasNear = false
            isRetreating = false
            setStartMarkerVisible(false)
            NotificationCenter.default.post(name: .arTrainingEvent, object: nil, userInfo: [BusKey.arevent: AREvent.userTappedToBeginActOut])
            return
        }

        // If gun is hidden (warningShown), user is tapping to confirm reset
        if warningShown {
            if isWaitingForResetSpeech {
                print("⏭️ [AR] Tap ignored - waiting for model to finish speaking")
                return
            }
            if isWaitingForStartMarker {
                if let frame = arView.session.currentFrame,
                   let dist = startMarkerDistanceFromCamera(frame: frame) {
                    print("⏭️ [AR] Tap ignored - \(String(format: "%.2f", dist))m from marker (need ≤\(markerReachDistance)m)")
                } else {
                    print("⏭️ [AR] Tap ignored - child hasn't reached the start marker yet (position unavailable)")
                }
                return
            }

            print("✅ [AR] User tapped to confirm reset - posting userTappedToReset event")
            setStartMarkerVisible(false)
            NotificationCenter.default.post(name: .arTrainingEvent, object: nil, userInfo: [BusKey.arevent: AREvent.userTappedToReset])
            return
        }

        // Only allow taps when armed for asset placement
        guard isArmed else {
            print("⏭️ [AR] Tap ignored - not armed and warningShown is false")
            return
        }

        // Check world mapping status before allowing placement
        if let frame = arView.session.currentFrame {
            let status = frame.worldMappingStatus
            if status == .notAvailable || status == .limited {
                print("⚠️ [AR] Cannot place object - insufficient mapping (status: \(statusDescription(status)))")
                showPlacementWarning(status: status)
                return
            }
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
        let asset = selectedAsset ?? "table"
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

            // If table was placed, automatically place gun on top of it
            if asset == "table" {
                placeGunOnTable(tableTransform: transform)
            }

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

        guard status == .mapped else {
            print("❌ World map not ready (status: \(status)). Walk around more.")
            showSaveAlert(success: false, message: "Please walk around more to map the environment.\n\nMapping status: \(statusDescription(status))")
            return
        }

        print("✅ World mapping status OK, getting world map...")
        attemptGetWorldMap(roomId: roomId, attemptsLeft: 4)
    }

    private func attemptGetWorldMap(roomId: String, attemptsLeft: Int) {
        guard let arView = arView else { return }
        arView.session.getCurrentWorldMap { [weak self] map, error in
            guard let self else { return }
            if let error = error {
                if attemptsLeft > 1 {
                    print("⚠️ getCurrentWorldMap failed (\(attemptsLeft - 1) attempts left): \(error.localizedDescription) — retrying in 2s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self.attemptGetWorldMap(roomId: roomId, attemptsLeft: attemptsLeft - 1)
                    }
                } else {
                    print("❌ getCurrentWorldMap failed after all attempts: \(error.localizedDescription)")
                    self.showSaveAlert(success: false, message: "Could not capture world map — please keep scanning the area and try again.")
                }
                return
            }
            guard let map = map else {
                self.showSaveAlert(success: false, message: "No world map data available")
                return
            }
            do {
                try WorldMapStore.save(map, roomId: roomId)
                print("✅ Saved map for '\(roomId)' (\(map.anchors.count) anchors)")
                self.showSaveAlert(success: true, message: "Room '\(roomId)' saved successfully!")
            } catch {
                print("❌ Save map failed:", error)
                self.showSaveAlert(success: false, message: "Failed to save: \(error.localizedDescription)")
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

    private func showPlacementWarning(status: ARFrame.WorldMappingStatus) {
        let message: String
        if status == .notAvailable {
            message = "Cannot place objects yet.\n\nPlease move your device slowly around the area to scan surfaces and create spatial anchors."
        } else {
            message = "Insufficient scanning detected.\n\nMove your device around to scan more of the floor and surrounding area before placing objects.\n\nMapping status: \(statusDescription(status))"
        }

        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootViewController = windowScene.windows.first?.rootViewController else {
                return
            }

            let alert = UIAlertController(
                title: "Scan More Area",
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
        var tableTransformToPlaceGun: simd_float4x4? = nil

        for a in anchors where a.name?.hasPrefix("placedAsset_") == true {
            // Parse asset type
            let components = a.name?.split(separator: "_") ?? []
            let asset = components.count > 1 ? String(components[1]) : "gun"

            // Skip gun anchors during restoration - gun will be auto-placed on table
            if asset == "gun" {
                print("⏭️ [AR] Skipping gun anchor restoration - will auto-place on table")
                continue
            }

            // Restore start marker (programmatic - no USDZ model needed)
            if asset == "startMarker" {
                let col = a.transform.columns.3
                startMarkerWorldPosition = SIMD3<Float>(col.x, col.y, col.z)
                if startMarkerAnchor != nil {
                    // Visual was already created by placeStartMarkerAtDevicePosition(); just track the AR anchor
                    startMarkerARAnch = a
                    print("📍 [AR] Start marker AR anchor registered (visual already placed)")
                } else if let entity = makeStartMarkerEntity() {
                    // Restoring from a saved world map — hidden until Orchestrator commands showStartMarker
                    let anchor = AnchorEntity(world: a.transform)
                    anchor.isEnabled = false
                    anchor.addChild(entity)
                    arView.scene.addAnchor(anchor)
                    startMarkerAnchor = anchor
                    startMarkerARAnch = a
                    print("📍 [AR] Start marker restored at saved position (hidden)")
                }
                continue
            }

            // Add to our tracked AR anchors
            placedARAnchors.append(a)

            // Spawn the model at the saved transform
            if let model = modelRoots[asset]?.clone(recursive: true) {
                layFlat(model, objectType: asset)
                model.position = [0, 0.01, 0]

                // Enable collision for tables so other objects can be placed on them
                if asset == "table" {
                    model.generateCollisionShapes(recursive: true)
                    // Save table transform to place gun on it after restoration
                    tableTransformToPlaceGun = a.transform
                }

                let entityAnchor = AnchorEntity(world: a.transform)
                entityAnchor.addChild(model)
                arView.scene.addAnchor(entityAnchor)
                placedAnchors.append(entityAnchor)

                print("Restored \(asset) at saved position")
                restoredAnyAsset = true

                // Only reset warningShown if gun is not currently hidden
                // Don't reset during reset mode (when savedGunAnchors has items)
                if savedGunAnchors.isEmpty {
                    warningShown = false
                }
            }
        }

        // Auto-place gun on table if table was restored
        if let tableTransform = tableTransformToPlaceGun {
            print("✅ [AR] Table restored, auto-placing gun on it")
            placeGunOnTable(tableTransform: tableTransform)
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

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let status = frame.worldMappingStatus
        guard status != lastMappingStatus else { return }
        lastMappingStatus = status
        let isReady = (status == .mapped || status == .extending)
        NotificationCenter.default.post(
            name: .mappingStatusChanged,
            object: nil,
            userInfo: ["isReady": isReady, "status": status.rawValue]
        )
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

        // Also clear start marker
        if let existing = startMarkerAnchor {
            arView?.scene.removeAnchor(existing)
            startMarkerAnchor = nil
        }
        if let existing = startMarkerARAnch {
            arView?.session.remove(anchor: existing)
            startMarkerARAnch = nil
        }

        currentAsset = nil
    }

    // MARK: - Auto-place gun on table

    private func placeGunOnTable(tableTransform: simd_float4x4) {
        guard let arView = arView,
              let gunModel = modelRoots["gun"]?.clone(recursive: true) else {
            print("⚠️ [AR] Cannot place gun: gun model not loaded")
            return
        }

        // Define gun offset relative to table center (X, Y, Z in meters)
        // Y: height above table, Z: forward/back, X: left/right
        let relativeOffset = SIMD3<Float>(0.0, 0.785, 0.40)  // Higher, toward back edge

        // Calculate gun transform based on table transform
        let tablePosition = SIMD3<Float>(
            tableTransform.columns.3.x,
            tableTransform.columns.3.y,
            tableTransform.columns.3.z
        )

        // Extract table's rotation matrix
        let rotationMatrix = simd_float3x3(
            SIMD3<Float>(tableTransform.columns.0.x, tableTransform.columns.0.y, tableTransform.columns.0.z),
            SIMD3<Float>(tableTransform.columns.1.x, tableTransform.columns.1.y, tableTransform.columns.1.z),
            SIMD3<Float>(tableTransform.columns.2.x, tableTransform.columns.2.y, tableTransform.columns.2.z)
        )

        // Rotate the offset by the table's orientation
        let rotatedOffset = rotationMatrix * relativeOffset
        let gunPosition = tablePosition + rotatedOffset

        // Create gun transform with same rotation as table
        var gunTransform = tableTransform
        gunTransform.columns.3 = SIMD4<Float>(gunPosition.x, gunPosition.y, gunPosition.z, 1.0)

        // Apply the gun's standard orientation
        layFlat(gunModel, objectType: "gun")

        // Rotate gun 180 degrees around Y axis (vertical) to face away from user
        let rotateAway = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        gunModel.orientation = rotateAway * gunModel.orientation

        gunModel.position = [0, 0.01, 0]

        // Create anchor and add to scene
        let gunAnchor = AnchorEntity(world: gunTransform)
        gunAnchor.addChild(gunModel)
        arView.scene.addAnchor(gunAnchor)
        placedAnchors.append(gunAnchor)

        // Create AR anchor for world map serialization
        let gunARAnch = ARAnchor(name: "placedAsset_gun", transform: gunTransform)
        arView.session.add(anchor: gunARAnch)
        placedARAnchors.append(gunARAnch)

        print("✅ [AR] Gun automatically placed on table at offset \(relativeOffset)")
    }

    // MARK: - Start Marker

    private func makeStartMarkerEntity() -> ModelEntity? {
        guard let arView else { return nil }
        _ = arView  // suppress unused warning
        // Flat red circle ~60cm diameter
        let mesh = MeshResource.generatePlane(width: 0.6, depth: 0.6, cornerRadius: 0.3)
        var mat = SimpleMaterial()
        mat.color = .init(tint: UIColor.systemRed.withAlphaComponent(0.85))
        mat.roughness = 1.0
        mat.metallic = 0.0
        return ModelEntity(mesh: mesh, materials: [mat])
    }

    func placeStartMarkerAtDevicePosition() {
        guard let arView else { return }

        // Remove any existing start marker
        if let existing = startMarkerAnchor {
            arView.scene.removeAnchor(existing)
            startMarkerAnchor = nil
        }
        if let existing = startMarkerARAnch {
            arView.session.remove(anchor: existing)
            startMarkerARAnch = nil
        }
        startMarkerWorldPosition = nil

        // Raycast straight down from camera world position to find floor directly below device
        guard let frame = arView.session.currentFrame else { return }
        let camCol = frame.camera.transform.columns.3
        let origin = SIMD3<Float>(camCol.x, camCol.y, camCol.z)
        let query = ARRaycastQuery(origin: origin, direction: SIMD3<Float>(0, -1, 0),
                                   allowing: .estimatedPlane, alignment: .horizontal)
        let results = arView.session.raycast(query)
        guard let hit = results.first else {
            print("⚠️ [AR] placeStartMarker: no floor hit below device")
            return
        }

        guard let entity = makeStartMarkerEntity() else { return }

        let anchor = AnchorEntity(world: hit.worldTransform)
        anchor.addChild(entity)
        arView.scene.addAnchor(anchor)
        startMarkerAnchor = anchor
        let col = hit.worldTransform.columns.3
        startMarkerWorldPosition = SIMD3<Float>(col.x, col.y, col.z)

        let arAnchor = ARAnchor(name: "placedAsset_startMarker", transform: hit.worldTransform)
        arView.session.add(anchor: arAnchor)
        startMarkerARAnch = arAnchor

        print("📍 [AR] Start marker placed at device feet")
    }

    func setStartMarkerVisible(_ visible: Bool) {
        guard let startMarkerAnchor else {
            print("⚠️ [AR] setStartMarkerVisible(\(visible)) called but no start marker is loaded")
            return
        }
        startMarkerAnchor.isEnabled = visible
        print("📍 [AR] Start marker visibility set to \(visible)")
    }

    func clearStartMarker() {
        if let existing = startMarkerAnchor {
            arView?.scene.removeAnchor(existing)
            startMarkerAnchor = nil
        }
        if let existing = startMarkerARAnch {
            arView?.session.remove(anchor: existing)
            startMarkerARAnch = nil
        }
        startMarkerWorldPosition = nil
    }

    private func startMarkerDistanceFromCamera(frame: ARFrame) -> Float? {
        guard let markerPos = startMarkerWorldPosition else { return nil }
        let cam = frame.camera.transform.columns.3
        let dx = cam.x - markerPos.x
        let dz = cam.z - markerPos.z
        return sqrtf(dx * dx + dz * dz)
    }
}
