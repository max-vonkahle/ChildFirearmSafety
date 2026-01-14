//
//  StereoARViewController.swift
//  Child Gun Safety
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

    // Preserve old config hook (so existing callers still compile)
    private var config = StereoConfig() {
        didSet {
            ipd = config.ipdMeters
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

        // --- Camera rig (head  left/right eyes) ---
        baseCameraNode.camera = SCNCamera()
        baseCameraNode.camera?.usesOrthographicProjection = false

        leftEye.camera = SCNCamera()
        rightEye.camera = SCNCamera()

        // Match ARFun FOV / near plane
        leftEye.camera?.fieldOfView = eyeFOV
        rightEye.camera?.fieldOfView = eyeFOV
        leftEye.camera?.zNear = 0.001
        rightEye.camera?.zNear = 0.001

        // Turn off auto exposure / HDR
        [baseCameraNode, leftEye, rightEye].forEach {
            $0.camera?.wantsHDR = false
            $0.camera?.wantsExposureAdaptation = false
        }

        // Position eyes using IPD
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
        let cfg = ARWorldTrackingConfiguration()
        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
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

        // Cardboard mask covers whole screen
        maskView.frame = view.bounds
        createCardboardMask()

        // Reticle overlay also covers whole screen
        reticleView.frame = view.bounds
        createReticle()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.pause()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // Keep camera aligned to ARKit head pose + store pixel buffer for GPU rendering
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Update head position immediately (fast)
        baseCameraNode.simdTransform = frame.camera.transform

        // Store pixel buffer reference for Metal rendering
        // IMPORTANT: We only store the pixel buffer, not the frame itself,
        // to avoid retaining ARFrames. The pixel buffer is released after each draw.
        frameLock.lock()
        currentPixelBuffer = frame.capturedImage
        frameLock.unlock()
    }

    // Restore models when anchors are loaded from world map
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
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
            } else {
                print("Warning: \(assetName) model template not loaded, cannot restore anchor")
            }
        }

        // Notify that assets are configured (matching ARCoordinator behavior)
        NotificationCenter.default.post(name: .assetsConfigured, object: nil)
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

    // MARK: - Cardboard reticle / mask (ported from ARFun)

    private func updateEyePositions() {
        leftEye.position = SCNVector3(-ipd / 2, 0, 0)
        rightEye.position = SCNVector3(ipd / 2, 0, 0)
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

        // Create render pipeline
        let library = device.makeDefaultLibrary()!
        let vertexFunction = library.makeFunction(name: "stereoPassthroughVertex")!
        let fragmentFunction = library.makeFunction(name: "stereoPassthroughFragment")!

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
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
}

// MARK: - MTKViewDelegate

extension StereoARViewController: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle size change if needed
    }

    func draw(in view: MTKView) {
        // Get the current pixel buffer
        frameLock.lock()
        guard let pixelBuffer = currentPixelBuffer else {
            frameLock.unlock()
            return
        }
        // Don't clear currentPixelBuffer here - we'll use it for both eyes
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
            // Flush texture cache every few frames to release old textures
            self.frameCounter += 1
            if self.frameCounter % 3 == 0 {
                CVMetalTextureCacheFlush(self.textureCache, 0)
            }
        }

        // Determine if this is left or right eye
        let isLeftEye = (view === leftMetalView)
        let stereoOffsetValue = Float(stereoOffset)

        // Create vertex data for a full-screen quad with stereo offset
        // The offset shifts the UV coordinates to create the stereo effect
        let leftOffset: Float = isLeftEye ? 0.0 : stereoOffsetValue
        let rightOffset: Float = isLeftEye ? stereoOffsetValue : 0.0

        // Vertices: position (x, y) and texCoord (u, v)
        // For landscape right orientation with front camera mirroring
        let vertices: [Float] = [
            // Position      // TexCoord (with stereo offset and orientation)
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
}
