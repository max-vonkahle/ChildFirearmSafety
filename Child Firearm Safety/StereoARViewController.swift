//
//  StereoARViewController.swift
//  Child Firearm Safety
//
//  Created by Max on 10/5/25.
//

import UIKit
import ARKit
import SceneKit
import MetalKit

final class StereoARViewController: UIViewController, ARSessionDelegate {
    // AR session
    private let session = ARSession()

    // SceneKit scene and camera rig
    private let scene = SCNScene()
    private let baseCameraNode = SCNNode()
    private let leftEye = SCNNode()
    private let rightEye = SCNNode()

    // Model templates and placed nodes (for loading saved rooms)
    private var modelTemplates: [String: SCNNode] = [:]  // asset name -> template node
    private var placedNodes: [SCNNode] = []  // All placed asset nodes
    private var hasNotifiedAssetsConfigured = false  // Ensure notification fires only once

    // Testing mode support
    var testingRoomId: String?
    var onTestingSceneReady: (() -> Void)?
    private var testingAssetTransforms: [String: simd_float4x4] = [:]
    private var testingAssetsPlaced = false
    private var relocalizationTimer: Timer?

    // GPU-accelerated passthrough views using Metal
    private var metalDevice: MTLDevice!
    private var leftMetalView: MTKView!
    private var rightMetalView: MTKView!
    private var commandQueue: MTLCommandQueue!
    private var textureCache: CVMetalTextureCache!
    private var pipelineState: MTLRenderPipelineState!
    private var sampler: MTLSamplerState!

    // SceneKit views (overlays for 3D content)
    private var leftSCNView: SCNView!
    private var rightSCNView: SCNView!

    // Cardboard mask  reticle (UIKit, like ARFun)
    private var maskView: UIView!
    private var reticleView: UIView!

    // Occlusion overlay views (renders camera where person is detected, on top of 3D)
    private var leftOcclusionView: MTKView!
    private var rightOcclusionView: MTKView!
    private var occlusionPipelineState: MTLRenderPipelineState!
    private var currentSegmentationBuffer: CVPixelBuffer?

    // Current frame texture (updated each frame, rendered by MTKView)
    private var currentPixelBuffer: CVPixelBuffer?
    private let frameLock = NSLock()
    private var frameCounter: Int = 0

    // Adjustable parameters for I/O 2015 Cardboard (matching ARFun)
    private let eyeFOV: CGFloat = 60.0
    private let cameraImageScale: CGFloat = 1.739
    // Default IPD; can still be overridden via StereoConfig if you want
    private var ipd: Float = 0.064
    // Horizontal offset as percentage of image width for stereo hack
    private let stereoOffset: CGFloat = 0.08
    // Screen/viewport parameters for off-axis projection
    private var screenAspect: Float = 16.0 / 9.0
    private let zNear: Float = 0.001
    private let zFar: Float = 100.0
    // Zero parallax distance - objects at this distance appear at screen depth
    // (no doubling). Objects closer appear in front, objects farther appear behind.
    private var zeroParallaxDistance: Float = 1.0

    // Preserve old config hook (so existing callers still compile)
    private var config = StereoConfig() {
        didSet {
            ipd = config.ipdMeters
            zeroParallaxDistance = config.zeroParallaxDistance
            updateEyePositions()
        }
    }

    // public init with custom config if you want
    convenience init(config: StereoConfig) {
        self.init(nibName: nil, bundle: nil)
        self.config = config
    }

    override func loadView() {
        view = UIView(frame: .zero)
        view.backgroundColor = .black
    }

    // Force Cardboard orientation like ARFun
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscapeRight
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // --- Listen for world map load notification ---
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLoadWorldMap(_:)),
            name: .loadWorldMap,
            object: nil
        )

        // --- Preload models ---
        preloadModel(named: "gun")
        preloadModel(named: "table")

        // --- Metal setup for GPU-accelerated camera passthrough ---
        setupMetal()

        // --- Metal views for camera passthrough ---
        leftMetalView = MTKView(frame: .zero, device: metalDevice)
        leftMetalView.delegate = self
        leftMetalView.framebufferOnly = true  // Set to true to reduce memory pressure
        leftMetalView.colorPixelFormat = .bgra8Unorm
        leftMetalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        leftMetalView.isPaused = false
        leftMetalView.enableSetNeedsDisplay = false
        leftMetalView.preferredFramesPerSecond = 60  // Match AR frame rate
        view.addSubview(leftMetalView)

        rightMetalView = MTKView(frame: .zero, device: metalDevice)
        rightMetalView.delegate = self
        rightMetalView.framebufferOnly = true  // Set to true to reduce memory pressure
        rightMetalView.colorPixelFormat = .bgra8Unorm
        rightMetalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rightMetalView.isPaused = false
        rightMetalView.enableSetNeedsDisplay = false
        rightMetalView.preferredFramesPerSecond = 60  // Match AR frame rate
        view.addSubview(rightMetalView)

        // --- SceneKit views for stereo 3D content ---
        leftSCNView = SCNView()
        leftSCNView.scene = scene
        leftSCNView.backgroundColor = .clear
        leftSCNView.isOpaque = false
        leftSCNView.rendersContinuously = true
        leftSCNView.isPlaying = true
        view.addSubview(leftSCNView)

        rightSCNView = SCNView()
        rightSCNView.scene = scene
        rightSCNView.backgroundColor = .clear
        rightSCNView.isOpaque = false
        rightSCNView.rendersContinuously = true
        rightSCNView.isPlaying = true
        view.addSubview(rightSCNView)

        // --- Occlusion overlay views (on top of SceneKit, renders camera where person detected) ---
        leftOcclusionView = MTKView(frame: .zero, device: metalDevice)
        leftOcclusionView.delegate = self
        leftOcclusionView.framebufferOnly = false  // Need to read for blending
        leftOcclusionView.colorPixelFormat = .bgra8Unorm
        leftOcclusionView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        leftOcclusionView.isPaused = false
        leftOcclusionView.enableSetNeedsDisplay = false
        leftOcclusionView.preferredFramesPerSecond = 60
        leftOcclusionView.isOpaque = false  // Allow transparency
        leftOcclusionView.layer.isOpaque = false
        view.addSubview(leftOcclusionView)

        rightOcclusionView = MTKView(frame: .zero, device: metalDevice)
        rightOcclusionView.delegate = self
        rightOcclusionView.framebufferOnly = false
        rightOcclusionView.colorPixelFormat = .bgra8Unorm
        rightOcclusionView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rightOcclusionView.isPaused = false
        rightOcclusionView.enableSetNeedsDisplay = false
        rightOcclusionView.preferredFramesPerSecond = 60
        rightOcclusionView.isOpaque = false
        rightOcclusionView.layer.isOpaque = false
        view.addSubview(rightOcclusionView)

        // --- Camera rig (head  left/right eyes) ---
        baseCameraNode.camera = SCNCamera()
        baseCameraNode.camera?.usesOrthographicProjection = false

        leftEye.camera = SCNCamera()
        rightEye.camera = SCNCamera()

        // Turn off auto exposure / HDR
        [baseCameraNode, leftEye, rightEye].forEach {
            $0.camera?.wantsHDR = false
            $0.camera?.wantsExposureAdaptation = false
        }

        // IMPORTANT: Do NOT set fieldOfView or zNear here - we'll use custom projectionTransform
        // Setting those properties can cause SceneKit to override our projection matrix

        // Position eyes using IPD and set up off-axis projection
        updateEyePositions()

        baseCameraNode.addChildNode(leftEye)
        baseCameraNode.addChildNode(rightEye)
        scene.rootNode.addChildNode(baseCameraNode)

        // Add lighting to the scene
        setupSceneLighting()

        // Gun model will be added when anchor is loaded via session(_:didAdd:)

        // Attach left/right eyes to SceneKit views
        leftSCNView.pointOfView = leftEye
        rightSCNView.pointOfView = rightEye

        // --- Cardboard mask  reticle (UIKit, like ARFun) ---
        maskView = UIView()
        maskView.backgroundColor = .black
        maskView.isUserInteractionEnabled = false
        view.addSubview(maskView)

        reticleView = UIView()
        reticleView.isUserInteractionEnabled = false
        view.addSubview(reticleView)

        // Initial reticle drawing
        createReticle()

        // --- ARKit session setup ---
        session.delegate = self
        if let roomId = testingRoomId {
            startTestingSession(roomId: roomId)
        } else {
            let cfg = ARWorldTrackingConfiguration()
            cfg.planeDetection = [.horizontal]

            if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                cfg.frameSemantics.insert(.personSegmentationWithDepth)
            } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation) {
                cfg.frameSemantics.insert(.personSegmentation)
            }

            session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let width = view.bounds.width / 2
        let height = view.bounds.height

        // Left/right halves for camera images (Metal views)
        leftMetalView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        rightMetalView.frame = CGRect(x: width, y: 0, width: width, height: height)

        // SceneKit views sit on top of the Metal views
        leftSCNView.frame = leftMetalView.frame
        rightSCNView.frame = rightMetalView.frame

        // Occlusion views sit on top of SceneKit views
        leftOcclusionView.frame = leftMetalView.frame
        rightOcclusionView.frame = rightMetalView.frame

        // Cardboard mask covers whole screen
        maskView.frame = view.bounds
        createCardboardMask()

        // Reticle overlay also covers whole screen
        reticleView.frame = view.bounds
        createReticle()

        // Update off-axis projection with new aspect ratio
        updateOffAxisProjection()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        relocalizationTimer?.invalidate()
        session.pause()
    }

    deinit {
        relocalizationTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // Keep camera aligned to ARKit head pose + store pixel buffer for GPU rendering
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        baseCameraNode.simdTransform = frame.camera.transform

        frameLock.lock()
        currentPixelBuffer = frame.capturedImage
        currentSegmentationBuffer = frame.segmentationBuffer
        frameLock.unlock()

        // Testing: wait for relocalization before placing assets
        if testingRoomId != nil && !testingAssetsPlaced {
            switch frame.worldMappingStatus {
            case .mapped, .extending:
                testingAssetsPlaced = true
                relocalizationTimer?.invalidate()
                print("✅ Testing world map relocalized - placing assets")
                DispatchQueue.main.async { [weak self] in
                    self?.placeTestingAssets()
                    self?.onTestingSceneReady?()
                }
            default:
                break
            }
        }
    }

    // Restore models when anchors are loaded from world map
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        var restoredAnyAsset = false

        for anchor in anchors where anchor.name?.hasPrefix("placedAsset_") == true {
            // Parse asset type from anchor name (e.g., "placedAsset_gun" -> "gun")
            let components = anchor.name?.split(separator: "_") ?? []
            let assetName = components.count > 1 ? String(components[1]) : "gun"

            print("Found saved \(assetName) anchor in stereo mode, restoring model...")

            // Clone and place the model
            if let modelNode = modelTemplates[assetName]?.clone() {
                // Position slightly above the anchor (match ARCoordinator)
                modelNode.position = SCNVector3(0, 0.01, 0)

                // Create a container node at the anchor's transform
                let containerNode = SCNNode()
                containerNode.simdTransform = anchor.transform
                containerNode.addChildNode(modelNode)

                // Add to scene
                scene.rootNode.addChildNode(containerNode)
                placedNodes.append(containerNode)

                print("\(assetName) model restored at saved position in stereo mode")
                restoredAnyAsset = true
            } else {
                print("Warning: \(assetName) model template not loaded, cannot restore anchor")
            }
        }

        // Only notify after ALL anchors in this batch are restored
        // Add slight delay to ensure all anchors are processed, and only notify once
        if restoredAnyAsset && !hasNotifiedAssetsConfigured {
            hasNotifiedAssetsConfigured = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                print("✅ All assets restored, notifying UI")
                NotificationCenter.default.post(name: .assetsConfigured, object: nil)
            }
        }
    }

    // MARK: - Gun Model and World Map Loading

    private func setupSceneLighting() {
        // Enable automatic default lighting to match RealityKit's behavior in regular AR view
        leftSCNView.autoenablesDefaultLighting = true
        rightSCNView.autoenablesDefaultLighting = true
    }

    private func preloadModel(named assetName: String) {
        guard let url = Bundle.main.url(forResource: assetName, withExtension: "usdz") else {
            print("" + assetName + " model not found in bundle")
            return
        }

        // Load USDZ and convert to SCNNode
        do {
            let loadedScene = try SCNScene(url: url, options: nil)

            // Get the root node that contains the model
            let modelNode = SCNNode()
            for child in loadedScene.rootNode.childNodes {
                modelNode.addChildNode(child.clone())
            }

            // Scale the model to match ARCoordinator's sizing
            let targetWidth: Float = assetName == "table" ? 1.0 : 0.18
            let bounds = modelNode.boundingBox
            let size = SCNVector3(
                bounds.max.x - bounds.min.x,
                bounds.max.y - bounds.min.y,
                bounds.max.z - bounds.min.z
            )
            let currentWidth = max(size.x, size.z)
            if currentWidth > 0 {
                let scale = targetWidth / currentWidth
                modelNode.scale = SCNVector3(scale, scale, scale)
            }

            // Rotate to lay flat (match ARCoordinator's layFlat) only if not a table
            if assetName != "table" {
                let rotation = SCNMatrix4MakeRotation(-.pi / 2, 1, 0, 0)
                modelNode.transform = SCNMatrix4Mult(rotation, modelNode.transform)
            }
            // Rotate table to lay flat in stereo mode
            if assetName == "table" {
                let rotation = SCNMatrix4MakeRotation(-.pi / 2, 1, 0, 0)
                modelNode.transform = SCNMatrix4Mult(rotation, modelNode.transform)
            }

            modelTemplates[assetName] = modelNode
            print("" + assetName + " model loaded successfully for stereo mode")
        } catch {
            print("Failed to load " + assetName + " model:", error)
        }
    }

    @objc private func handleLoadWorldMap(_ notification: Notification) {
        let roomId = (notification.userInfo?["roomId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveId = roomId?.isEmpty == false ? roomId! : "default"

        // Reset notification flag for new room
        hasNotifiedAssetsConfigured = false

        do {
            let map = try WorldMapStore.load(roomId: effectiveId)
            let cfg = ARWorldTrackingConfiguration()
            cfg.planeDetection = [.horizontal]

            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                cfg.sceneReconstruction = .mesh
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

            // Pause first to avoid "already-enabled session" warning
            session.pause()

            // Small delay to ensure session is fully paused
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                self.session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
                print("Loaded world map for \(effectiveId) in stereo mode. Anchors will appear in session(_:didAdd:)")
            }
        } catch {
            print("Failed to load world map in stereo mode:", error)
        }
    }

    // MARK: - Testing Mode

    private func startTestingSession(roomId: String) {
        guard let roomData = RoomLibrary.loadTestingRoom(roomId: roomId) else {
            print("⚠️ Failed to load testing room: \(roomId)")
            onTestingSceneReady?()
            return
        }

        testingAssetTransforms = roomData.assets

        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = [.horizontal]
        cfg.initialWorldMap = roomData.worldMap

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            cfg.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            cfg.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            cfg.frameSemantics.insert(.personSegmentationWithDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation) {
            cfg.frameSemantics.insert(.personSegmentation)
        }

        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        print("✅ Testing AR session started with world map (\(roomData.worldMap.anchors.count) anchors)")

        // Fallback: place assets after 10s even if not fully relocalized
        relocalizationTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            guard let self = self, !self.testingAssetsPlaced else { return }
            print("⏱️ Testing relocalization timeout - placing assets anyway")
            self.testingAssetsPlaced = true
            self.placeTestingAssets()
            self.onTestingSceneReady?()
        }
    }

    private func placeTestingAssets() {
        print("\n🔧 === PLACING TESTING ASSETS (STEREO) ===")

        guard let kitchenTransform = testingAssetTransforms["kitchen"] else {
            print("⚠️ No kitchen transform in testing room data")
            return
        }

        // Kitchen at natural size (no scaling — matches TestingARViewController)
        placeTestingModel(named: "kitchen", at: kitchenTransform)

        // Gun scaled to 0.2m, positioned relative to kitchen
        let relativeOffset = SIMD3<Float>(0.5823, 0.8431, -2.5297)
        let gunTransform = calculateTestingGunTransform(kitchenTransform: kitchenTransform, relativeOffset: relativeOffset)
        placeTestingModel(named: "gun", at: gunTransform, targetWidth: 0.2, isGun: true)

        print("=== TESTING ASSET PLACEMENT COMPLETE ===\n")
    }

    private func placeTestingModel(named name: String, at transform: simd_float4x4, targetWidth: Float? = nil, isGun: Bool = false) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "usdz") else {
            print("⚠️ \(name).usdz not found")
            return
        }

        do {
            let loadedScene = try SCNScene(url: url, options: nil)
            let modelNode = SCNNode()
            for child in loadedScene.rootNode.childNodes {
                modelNode.addChildNode(child.clone())
            }

            // Scale if a target width is specified
            if let targetWidth = targetWidth {
                let bounds = modelNode.boundingBox
                let size = SCNVector3(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)
                let currentWidth = max(size.x, size.z)
                if currentWidth > 0 {
                    let scale = targetWidth / currentWidth
                    modelNode.scale = SCNVector3(scale, scale, scale)
                    print("📏 Scaled \(name): \(currentWidth)m -> \(targetWidth)m (factor: \(scale))")
                }
            }

            // Correct USDZ base orientation (-90° X)
            let rotX90 = SCNMatrix4MakeRotation(-.pi / 2, 1, 0, 0)
            modelNode.transform = SCNMatrix4Mult(rotX90, modelNode.transform)

            // Additional gun-specific orientation corrections
            if isGun {
                let rotX = SCNMatrix4MakeRotation(-.pi / 2, 1, 0, 0)
                let rotZ = SCNMatrix4MakeRotation(.pi / 2, 0, 0, 1)
                modelNode.transform = SCNMatrix4Mult(rotZ, SCNMatrix4Mult(rotX, modelNode.transform))
            }

            // Wrap in a container positioned at the saved world-space transform
            let containerNode = SCNNode()
            containerNode.simdTransform = transform
            containerNode.addChildNode(modelNode)
            scene.rootNode.addChildNode(containerNode)

            let pos = transform.columns.3
            print("✅ Placed \(name) at (\(pos.x), \(pos.y), \(pos.z))")
        } catch {
            print("❌ Failed to load \(name): \(error)")
        }
    }

    private func calculateTestingGunTransform(kitchenTransform: simd_float4x4, relativeOffset: SIMD3<Float>) -> simd_float4x4 {
        let kitchenPosition = SIMD3<Float>(
            kitchenTransform.columns.3.x,
            kitchenTransform.columns.3.y,
            kitchenTransform.columns.3.z
        )
        let rotationMatrix = simd_float3x3(
            SIMD3<Float>(kitchenTransform.columns.0.x, kitchenTransform.columns.0.y, kitchenTransform.columns.0.z),
            SIMD3<Float>(kitchenTransform.columns.1.x, kitchenTransform.columns.1.y, kitchenTransform.columns.1.z),
            SIMD3<Float>(kitchenTransform.columns.2.x, kitchenTransform.columns.2.y, kitchenTransform.columns.2.z)
        )
        let rotatedOffset = rotationMatrix * relativeOffset
        let gunPosition = kitchenPosition + rotatedOffset
        var gunTransform = kitchenTransform
        gunTransform.columns.3 = SIMD4<Float>(gunPosition.x, gunPosition.y, gunPosition.z, 1.0)
        return gunTransform
    }

    // MARK: - Cardboard reticle / mask (ported from ARFun)

    private func updateEyePositions() {
        // IMPORTANT: Both eyes are at the SAME position (no physical IPD offset)
        // because the camera passthrough already has stereo baked in via UV shifting.
        // We only shift the 3D frustum to match that UV shift.
        leftEye.position = SCNVector3Zero
        rightEye.position = SCNVector3Zero

        // Reset any rotation - eyes look straight ahead (parallel)
        leftEye.eulerAngles = SCNVector3Zero
        rightEye.eulerAngles = SCNVector3Zero

        // Apply shifted projection matrices to match camera passthrough
        updateOffAxisProjection()
    }

    /// Creates a projection matrix with horizontal frustum shift to match the camera passthrough stereo.
    ///
    /// Since the camera passthrough shifts UV coordinates by `stereoOffset` (8%), we need to
    /// shift the 3D projection by the same amount so virtual objects align with the background.
    ///
    /// - Parameters:
    ///   - horizontalShift: Frustum shift as fraction of width (-stereoOffset for left, +stereoOffset for right)
    ///   - aspect: Viewport aspect ratio (width/height)
    ///   - fovY: Vertical field of view in degrees
    ///   - near: Near clipping plane
    ///   - far: Far clipping plane
    /// - Returns: SCNMatrix4 projection matrix
    private func createShiftedProjectionMatrix(
        horizontalShift: Float,
        aspect: Float,
        fovY: Float,
        near: Float,
        far: Float
    ) -> SCNMatrix4 {
        // Convert FOV to radians
        let fovYRad = fovY * .pi / 180.0

        // Calculate the half-height and half-width of the near plane
        let top = near * tan(fovYRad / 2.0)
        let bottom = -top
        let halfWidth = top * aspect

        // The camera passthrough shifts UVs by stereoOffset (e.g., 8%)
        // To match, we shift the frustum by the same percentage of its width
        // horizontalShift is the fraction to shift (negative = shift left, positive = shift right)
        let shift = halfWidth * 2.0 * horizontalShift

        // Apply the shift to create asymmetric frustum
        let left = -halfWidth + shift
        let right = halfWidth + shift

        // Build the projection matrix (OpenGL/SceneKit convention)
        let a = (right + left) / (right - left)
        let b = (top + bottom) / (top - bottom)
        let c = -(far + near) / (far - near)
        let d = -(2.0 * far * near) / (far - near)
        let e = (2.0 * near) / (right - left)
        let f = (2.0 * near) / (top - bottom)

        return SCNMatrix4(
            m11: e,   m12: 0,   m13: 0,   m14: 0,
            m21: 0,   m22: f,   m23: 0,   m24: 0,
            m31: a,   m32: b,   m33: c,   m34: -1,
            m41: 0,   m42: 0,   m43: d,   m44: 0
        )
    }

    private func updateOffAxisProjection() {
        // Calculate aspect ratio from the viewport
        let viewWidth = view.bounds.width / 2  // Each eye gets half the screen
        let viewHeight = view.bounds.height
        if viewHeight > 0 {
            screenAspect = Float(viewWidth / viewHeight)
        }

        // The camera passthrough creates "fake stereo" by cropping different parts of the image:
        // - Left eye:  UVs from 0.0 to 0.92 (crops 8% from right) - shows more LEFT of scene
        // - Right eye: UVs from 0.08 to 1.0 (crops 8% from left) - shows more RIGHT of scene
        //
        // For 3D objects to align with this, we need to shift the projection in the SAME direction.
        // A positive horizontal shift moves the frustum right (showing more of the LEFT side of 3D space)
        // A negative horizontal shift moves the frustum left (showing more of the RIGHT side of 3D space)
        //
        // So:
        // - Left eye needs positive shift (to show more left, matching camera)
        // - Right eye needs negative shift (to show more right, matching camera)
        let offsetFraction = Float(stereoOffset)

        // Apply stereo multiplier for debugging/tuning
        let effectiveOffset = offsetFraction * stereoMultiplier

        // Create projection for left eye
        // Camera UVs [0, 0.92]: content shifts LEFT on screen (right side cropped)
        // To match: 3D projection must shift LEFT on screen -> negative shift
        let leftProjection = createShiftedProjectionMatrix(
            horizontalShift: -effectiveOffset / 2.0,
            aspect: screenAspect,
            fovY: Float(eyeFOV),
            near: zNear,
            far: zFar
        )

        // Create projection for right eye  
        // Camera UVs [0.08, 1.0]: content shifts RIGHT on screen (left side cropped)
        // To match: 3D projection must shift RIGHT on screen -> positive shift
        let rightProjection = createShiftedProjectionMatrix(
            horizontalShift: effectiveOffset / 2.0,
            aspect: screenAspect,
            fovY: Float(eyeFOV),
            near: zNear,
            far: zFar
        )

        // Apply to cameras
        leftEye.camera?.projectionTransform = leftProjection
        rightEye.camera?.projectionTransform = rightProjection

        // Debug: Print the projection parameters
        print("[StereoDebug] effectiveOffset: \(effectiveOffset), screenAspect: \(screenAspect)")
        print("[StereoDebug] Left projection m31 (a): \(leftProjection.m31)")
        print("[StereoDebug] Right projection m31 (a): \(rightProjection.m31)")
    }

    private func createReticle() {
        // Clear previous reticle
        reticleView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }

        let width = view.bounds.width / 2
        let height = view.bounds.height

        // Reticle parameters
        let reticleSize: CGFloat = 20  // Size of the dot

        // Optical center offset (tuned for your I/O 2015 Cardboard)
        let opticalCenterRatio: CGFloat = 0.45

        // White dots with slight transparency
        let dotColor = UIColor.white.withAlphaComponent(0.8).cgColor

        // Left eye reticle - positioned from the right edge (inside edge) of left half
        let leftCenter = CGPoint(x: width * (1 - opticalCenterRatio), y: height / 2)

        let leftDot = CAShapeLayer()
        leftDot.path = UIBezierPath(
            ovalIn: CGRect(
                x: leftCenter.x - reticleSize / 2,
                y: leftCenter.y - reticleSize / 2,
                width: reticleSize,
                height: reticleSize
            )
        ).cgPath
        leftDot.fillColor = dotColor

        // Left ring
        let leftRing = CAShapeLayer()
        leftRing.path = UIBezierPath(
            ovalIn: CGRect(
                x: leftCenter.x - reticleSize / 2 - 2,
                y: leftCenter.y - reticleSize / 2 - 2,
                width: reticleSize + 4,
                height: reticleSize + 4
            )
        ).cgPath
        leftRing.fillColor = UIColor.clear.cgColor
        leftRing.strokeColor = dotColor
        leftRing.lineWidth = 2

        // Right eye reticle - positioned from the left edge (inside edge) of right half
        let rightCenter = CGPoint(x: width + (width * opticalCenterRatio), y: height / 2)

        let rightDot = CAShapeLayer()
        rightDot.path = UIBezierPath(
            ovalIn: CGRect(
                x: rightCenter.x - reticleSize / 2,
                y: rightCenter.y - reticleSize / 2,
                width: reticleSize,
                height: reticleSize
            )
        ).cgPath
        rightDot.fillColor = dotColor

        // Right ring
        let rightRing = CAShapeLayer()
        rightRing.path = UIBezierPath(
            ovalIn: CGRect(
                x: rightCenter.x - reticleSize / 2 - 2,
                y: rightCenter.y - reticleSize / 2 - 2,
                width: reticleSize + 4,
                height: reticleSize + 4
            )
        ).cgPath
        rightRing.fillColor = UIColor.clear.cgColor
        rightRing.strokeColor = dotColor
        rightRing.lineWidth = 2

        reticleView.layer.addSublayer(leftRing)
        reticleView.layer.addSublayer(leftDot)
        reticleView.layer.addSublayer(rightRing)
        reticleView.layer.addSublayer(rightDot)
    }

    private func createCardboardMask() {
        let width = view.bounds.width / 2
        let height = view.bounds.height

        // Base path = full screen
        let maskPath = UIBezierPath(rect: view.bounds)

        // Lens parameters (tuned for I/O 2015 Cardboard)
        let lensRadius = min(width, height) * 0.45
        let lensCenterY = height / 2
        let lensOffsetX = width * 0.5

        // Centers for each lens
        let leftLensCenter = CGPoint(x: lensOffsetX, y: lensCenterY)
        let rightLensCenter = CGPoint(x: width + lensOffsetX, y: lensCenterY)

        let leftLensPath = UIBezierPath(
            arcCenter: leftLensCenter,
            radius: lensRadius,
            startAngle: 0,
            endAngle: .pi * 2,
            clockwise: true
        )
        let rightLensPath = UIBezierPath(
            arcCenter: rightLensCenter,
            radius: lensRadius,
            startAngle: 0,
            endAngle: .pi * 2,
            clockwise: true
        )

        // Subtract lenses from mask
        maskPath.append(leftLensPath.reversing())
        maskPath.append(rightLensPath.reversing())

        let maskLayer = CAShapeLayer()
        maskLayer.path = maskPath.cgPath
        maskLayer.fillRule = .evenOdd
        maskView.layer.mask = maskLayer
    }

    // MARK: - Public hooks (preserved)

    // Expose session for external AR content anchoring if needed (same as before)
    var arSession: ARSession { session }

    func apply(config newConfig: StereoConfig) {
        config = newConfig
    }

    /// Adjust the zero parallax distance at runtime.
    /// Objects at this distance will appear at screen depth (no doubling).
    /// - Parameter distance: Distance in meters (typical range: 0.5 - 3.0m)
    func setZeroParallaxDistance(_ distance: Float) {
        zeroParallaxDistance = max(0.1, distance)  // Clamp to minimum safe value
        updateOffAxisProjection()
    }

    /// Get current zero parallax distance
    var currentZeroParallaxDistance: Float {
        zeroParallaxDistance
    }

    /// Debug: Set stereo offset multiplier (0 = no stereo, 1 = normal, 2 = exaggerated)
    /// Use this to tune the stereo strength or disable it for testing
    func setStereoMultiplier(_ multiplier: Float) {
        stereoMultiplier = multiplier
        updateOffAxisProjection()
    }

    // Debug multiplier for stereo effect (1.0 = normal)
    private var stereoMultiplier: Float = 1.0

    // MARK: - Metal Setup

    private func setupMetal() {
        // Get Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        metalDevice = device
        commandQueue = device.makeCommandQueue()!

        // Create texture cache for CVPixelBuffer -> MTLTexture conversion
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        self.textureCache = textureCache!

        // Create sampler state
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)!

        // Create render pipeline for camera passthrough
        let library = device.makeDefaultLibrary()!
        let vertexFunction = library.makeFunction(name: "stereoPassthroughVertex")!
        let fragmentFunction = library.makeFunction(name: "stereoPassthroughFragment")!

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        // Create render pipeline for occlusion overlay (with alpha blending)
        let occlusionFragmentFunction = library.makeFunction(name: "stereoOcclusionFragment")!
        
        let occlusionPipelineDescriptor = MTLRenderPipelineDescriptor()
        occlusionPipelineDescriptor.vertexFunction = vertexFunction
        occlusionPipelineDescriptor.fragmentFunction = occlusionFragmentFunction
        occlusionPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        // Enable alpha blending
        occlusionPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        occlusionPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        occlusionPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        occlusionPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        occlusionPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        occlusionPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        occlusionPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        occlusionPipelineState = try! device.makeRenderPipelineState(descriptor: occlusionPipelineDescriptor)
    }

    private func createTexture(from pixelBuffer: CVPixelBuffer, planeIndex: Int) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)

        let format: MTLPixelFormat = planeIndex == 0 ? .r8Unorm : .rg8Unorm

        var textureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            format,
            width,
            height,
            planeIndex,
            &textureRef
        )

        guard status == kCVReturnSuccess, let textureRef = textureRef else {
            return nil
        }

        return CVMetalTextureGetTexture(textureRef)
    }

    /// Create texture from a single-plane pixel buffer (like segmentation mask)
    private func createSinglePlaneTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Segmentation buffer is typically 8-bit single channel
        var textureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            .r8Unorm,
            width,
            height,
            0,
            &textureRef
        )

        guard status == kCVReturnSuccess, let textureRef = textureRef else {
            return nil
        }

        return CVMetalTextureGetTexture(textureRef)
    }
}

// MARK: - MTKViewDelegate

extension StereoARViewController: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle size change if needed
    }

    func draw(in view: MTKView) {
        // Determine which type of view this is
        let isPassthroughView = (view === leftMetalView || view === rightMetalView)
        let isOcclusionView = (view === leftOcclusionView || view === rightOcclusionView)
        
        if isPassthroughView {
            drawPassthrough(in: view)
        } else if isOcclusionView {
            drawOcclusion(in: view)
        }
    }

    private func drawPassthrough(in view: MTKView) {
        // Get the current pixel buffer
        frameLock.lock()
        guard let pixelBuffer = currentPixelBuffer else {
            frameLock.unlock()
            return
        }
        frameLock.unlock()

        // Create textures from pixel buffer (YCbCr format from camera)
        guard let yTexture = createTexture(from: pixelBuffer, planeIndex: 0),
              let cbcrTexture = createTexture(from: pixelBuffer, planeIndex: 1) else {
            return
        }

        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        // Add completion handler to flush texture cache periodically
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            self.frameCounter += 1
            if self.frameCounter % 6 == 0 {  // Less frequent flushing
                CVMetalTextureCacheFlush(self.textureCache, 0)
            }
        }

        // Determine if this is left or right eye
        let isLeftEye = (view === leftMetalView)
        let stereoOffsetValue = Float(stereoOffset)

        // Create vertex data for a full-screen quad with stereo offset
        let leftOffset: Float = isLeftEye ? 0.0 : stereoOffsetValue
        let rightOffset: Float = isLeftEye ? stereoOffsetValue : 0.0

        let vertices: [Float] = [
            -1.0, -1.0,      leftOffset, 1.0,
             1.0, -1.0,      1.0 - rightOffset, 1.0,
            -1.0,  1.0,      leftOffset, 0.0,
             1.0,  1.0,      1.0 - rightOffset, 0.0,
        ]

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBytes(vertices, length: vertices.count * MemoryLayout<Float>.size, index: 0)
        renderEncoder.setFragmentTexture(yTexture, index: 0)
        renderEncoder.setFragmentTexture(cbcrTexture, index: 1)
        renderEncoder.setFragmentSamplerState(sampler, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func drawOcclusion(in view: MTKView) {
        // Get the current buffers
        frameLock.lock()
        guard let pixelBuffer = currentPixelBuffer,
              let segmentationBuffer = currentSegmentationBuffer else {
            frameLock.unlock()
            return
        }
        frameLock.unlock()

        // Create textures
        guard let yTexture = createTexture(from: pixelBuffer, planeIndex: 0),
              let cbcrTexture = createTexture(from: pixelBuffer, planeIndex: 1),
              let segmentationTexture = createSinglePlaneTexture(from: segmentationBuffer) else {
            return
        }

        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        // Clear to transparent
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        // Determine if this is left or right eye
        let isLeftEye = (view === leftOcclusionView)
        let stereoOffsetValue = Float(stereoOffset)

        // Same stereo offset as passthrough
        let leftOffset: Float = isLeftEye ? 0.0 : stereoOffsetValue
        let rightOffset: Float = isLeftEye ? stereoOffsetValue : 0.0

        let vertices: [Float] = [
            -1.0, -1.0,      leftOffset, 1.0,
             1.0, -1.0,      1.0 - rightOffset, 1.0,
            -1.0,  1.0,      leftOffset, 0.0,
             1.0,  1.0,      1.0 - rightOffset, 0.0,
        ]

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        renderEncoder.setRenderPipelineState(occlusionPipelineState)
        renderEncoder.setVertexBytes(vertices, length: vertices.count * MemoryLayout<Float>.size, index: 0)
        renderEncoder.setFragmentTexture(yTexture, index: 0)
        renderEncoder.setFragmentTexture(cbcrTexture, index: 1)
        renderEncoder.setFragmentTexture(segmentationTexture, index: 2)
        renderEncoder.setFragmentSamplerState(sampler, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
