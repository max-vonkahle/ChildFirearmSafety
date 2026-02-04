//
//  VirtualKitchenView.swift
//  Child Gun Safety
//
//  Virtual SceneKit environment displaying a kitchen with placed gun asset
//  Supports both regular and cardboard/stereo modes
//

import SwiftUI
import SceneKit
import simd

struct VirtualKitchenView: UIViewControllerRepresentable {
    let roomId: String?
    let onSceneReady: () -> Void
    @AppStorage("cardboardMode") private var cardboardMode = false

    func makeUIViewController(context: Context) -> VirtualKitchenViewController {
        let vc = VirtualKitchenViewController()
        vc.roomId = roomId
        vc.onSceneReady = onSceneReady
        vc.cardboardMode = cardboardMode
        return vc
    }

    func updateUIViewController(_ uiViewController: VirtualKitchenViewController, context: Context) {
        // Update cardboard mode if changed
        uiViewController.cardboardMode = cardboardMode
    }
}

final class VirtualKitchenViewController: UIViewController {
    var roomId: String?
    var onSceneReady: (() -> Void)?
    var cardboardMode: Bool = false {
        didSet {
            if isViewLoaded {
                setupViews()
            }
        }
    }

    // Regular mode
    private var scnView: SCNView?

    // Stereo mode
    private var leftSCNView: SCNView?
    private var rightSCNView: SCNView?
    private var maskView: UIView?

    private let scene = SCNScene()
    private var baseCameraNode: SCNNode!
    private var leftEyeNode: SCNNode?
    private var rightEyeNode: SCNNode?

    // Interpupillary distance (distance between eyes)
    private let ipd: Float = 0.064  // 64mm average

    // Asset transforms from saved room
    private var assetTransforms: [String: simd_float4x4] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        print("\n🎬 VirtualKitchenView viewDidLoad")
        print("📋 roomId parameter: \(roomId ?? "nil")")

        // Load room data if available
        if let roomId = roomId {
            print("🔍 Attempting to load testing room: '\(roomId)'")
            if let roomData = RoomLibrary.loadTestingRoom(roomId: roomId) {
                assetTransforms = roomData.assets
                print("✅ Loaded testing room '\(roomId)' with \(assetTransforms.count) assets")
                print("   Asset keys: \(assetTransforms.keys.sorted())")
            } else {
                print("⚠️ Failed to load testing room: \(roomId)")
            }
        } else {
            print("⚠️ No roomId provided to VirtualKitchenView")
        }

        setupScene()
        setupViews()
        placeAssets()

        // Notify that scene is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.onSceneReady?()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateViewFrames()
    }

    private func setupScene() {
        // Setup base camera node (center between eyes)
        baseCameraNode = SCNNode()
        baseCameraNode.position = SCNVector3(x: 0, y: 1.6, z: 2.5)  // Eye level, back from center
        baseCameraNode.eulerAngles = SCNVector3(x: -.pi / 12, y: 0, z: 0)  // Look slightly down
        scene.rootNode.addChildNode(baseCameraNode)

        // Add lighting
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.color = UIColor.white
        ambientLight.light?.intensity = 500
        scene.rootNode.addChildNode(ambientLight)

        let directionalLight = SCNNode()
        directionalLight.light = SCNLight()
        directionalLight.light?.type = .directional
        directionalLight.light?.color = UIColor.white
        directionalLight.light?.intensity = 800
        directionalLight.eulerAngles = SCNVector3(x: -.pi / 3, y: .pi / 4, z: 0)
        scene.rootNode.addChildNode(directionalLight)
    }

    private func setupViews() {
        // Remove existing views
        scnView?.removeFromSuperview()
        leftSCNView?.removeFromSuperview()
        rightSCNView?.removeFromSuperview()
        maskView?.removeFromSuperview()
        leftEyeNode?.removeFromParentNode()
        rightEyeNode?.removeFromParentNode()

        if cardboardMode {
            setupStereoViews()
        } else {
            setupRegularView()
        }
    }

    private func setupRegularView() {
        // Single SceneKit view for regular mode
        scnView = SCNView(frame: view.bounds)
        scnView?.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scnView?.scene = scene
        scnView?.backgroundColor = .black
        scnView?.allowsCameraControl = false
        scnView?.autoenablesDefaultLighting = true

        // Use base camera directly
        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = 100
        baseCameraNode.camera = camera
        scnView?.pointOfView = baseCameraNode

        if let scnView = scnView {
            view.addSubview(scnView)
        }
    }

    private func setupStereoViews() {
        let width = view.bounds.width / 2
        let height = view.bounds.height

        // Left eye camera
        leftEyeNode = SCNNode()
        leftEyeNode?.camera = SCNCamera()
        leftEyeNode?.camera?.zNear = 0.01
        leftEyeNode?.camera?.zFar = 100
        leftEyeNode?.position = SCNVector3(-ipd / 2, 0, 0)  // Half IPD to the left
        baseCameraNode.addChildNode(leftEyeNode!)

        // Right eye camera
        rightEyeNode = SCNNode()
        rightEyeNode?.camera = SCNCamera()
        rightEyeNode?.camera?.zNear = 0.01
        rightEyeNode?.camera?.zFar = 100
        rightEyeNode?.position = SCNVector3(ipd / 2, 0, 0)  // Half IPD to the right
        baseCameraNode.addChildNode(rightEyeNode!)

        // Left SceneKit view
        leftSCNView = SCNView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        leftSCNView?.scene = scene
        leftSCNView?.backgroundColor = .black
        leftSCNView?.pointOfView = leftEyeNode
        leftSCNView?.autoenablesDefaultLighting = true
        leftSCNView?.isPlaying = true

        // Right SceneKit view
        rightSCNView = SCNView(frame: CGRect(x: width, y: 0, width: width, height: height))
        rightSCNView?.scene = scene
        rightSCNView?.backgroundColor = .black
        rightSCNView?.pointOfView = rightEyeNode
        rightSCNView?.autoenablesDefaultLighting = true
        rightSCNView?.isPlaying = true

        if let leftSCNView = leftSCNView, let rightSCNView = rightSCNView {
            view.addSubview(leftSCNView)
            view.addSubview(rightSCNView)
        }

        // Add cardboard mask
        setupCardboardMask()
    }

    private func setupCardboardMask() {
        maskView = UIView(frame: view.bounds)
        maskView?.backgroundColor = .clear
        maskView?.isUserInteractionEnabled = false
        maskView?.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        if let maskView = maskView {
            view.addSubview(maskView)
            createCardboardMask()
        }
    }

    private func createCardboardMask() {
        guard let maskView = maskView else { return }

        let width = view.bounds.width / 2
        let height = view.bounds.height

        // Base path = full screen (black)
        let maskPath = UIBezierPath(rect: view.bounds)

        // Lens parameters (Google Cardboard I/O 2015 specs)
        let lensRadius = min(width, height) * 0.45
        let lensCenterY = height / 2
        let lensOffsetX = width * 0.5

        // Centers for each lens (transparent circles)
        let leftLensCenter = CGPoint(x: lensOffsetX, y: lensCenterY)
        let rightLensCenter = CGPoint(x: width + lensOffsetX, y: lensCenterY)

        // Cut out circles for lenses
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

        // Subtract lens circles from full screen (creates transparent areas)
        maskPath.append(leftLensPath.reversing())
        maskPath.append(rightLensPath.reversing())

        // Apply mask
        let maskLayer = CAShapeLayer()
        maskLayer.path = maskPath.cgPath
        maskLayer.fillRule = .evenOdd
        maskLayer.fillColor = UIColor.black.cgColor
        maskView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        maskView.layer.addSublayer(maskLayer)
    }

    private func updateViewFrames() {
        if cardboardMode {
            let width = view.bounds.width / 2
            let height = view.bounds.height

            leftSCNView?.frame = CGRect(x: 0, y: 0, width: width, height: height)
            rightSCNView?.frame = CGRect(x: width, y: 0, width: width, height: height)
            maskView?.frame = view.bounds
            createCardboardMask()
        } else {
            scnView?.frame = view.bounds
        }
    }

    private func loadAsset(named assetName: String, at transform: simd_float4x4) {
        guard let assetURL = Bundle.main.url(forResource: assetName, withExtension: "usdz") else {
            print("⚠️ \(assetName) model not found")
            return
        }

        do {
            let assetScene = try SCNScene(url: assetURL, options: [
                .checkConsistency: true,
                .flattenScene: false
            ])

            // Create a container node for the asset
            let assetContainer = SCNNode()

            // Add all asset nodes to container
            for childNode in assetScene.rootNode.childNodes {
                let assetNode = childNode.clone()
                assetNode.position = SCNVector3(0, 0, 0)
                assetContainer.addChildNode(assetNode)
            }

            // Apply proper scaling
            let scaleFactor = getScaleFactor(for: assetName, node: assetContainer)
            assetContainer.scale = SCNVector3(scaleFactor, scaleFactor, scaleFactor)

            // Extract position from transform
            let position = transform.columns.3
            assetContainer.position = SCNVector3(Float(position.x), Float(position.y), Float(position.z))

            // Extract rotation from transform matrix
            let rotationMatrix = SCNMatrix4(
                m11: Float(transform.columns.0.x), m12: Float(transform.columns.0.y), m13: Float(transform.columns.0.z), m14: Float(transform.columns.0.w),
                m21: Float(transform.columns.1.x), m22: Float(transform.columns.1.y), m23: Float(transform.columns.1.z), m24: Float(transform.columns.1.w),
                m31: Float(transform.columns.2.x), m32: Float(transform.columns.2.y), m33: Float(transform.columns.2.z), m34: Float(transform.columns.2.w),
                m41: 0, m42: 0, m43: 0, m44: 1
            )
            assetContainer.transform = rotationMatrix

            // Correct USDZ base orientation (-90° X)
            let rotX90 = SCNMatrix4MakeRotation(-.pi / 2, 1, 0, 0)
            assetContainer.transform = SCNMatrix4Mult(rotX90, assetContainer.transform)

            // Re-apply position after transform
            assetContainer.position = SCNVector3(Float(position.x), Float(position.y), Float(position.z))

            scene.rootNode.addChildNode(assetContainer)

            print("✅ \(assetName) loaded at position: (\(position.x), \(position.y), \(position.z)) with scale: \(scaleFactor)")

            // Debug: Print bounding box in world space
            let bbox = assetContainer.boundingBox
            let bboxSize = SCNVector3(bbox.max.x - bbox.min.x, bbox.max.y - bbox.min.y, bbox.max.z - bbox.min.z)
            print("   📦 Bounding box size: (\(bboxSize.x), \(bboxSize.y), \(bboxSize.z))")
        } catch {
            print("❌ Failed to load \(assetName): \(error)")
        }
    }

    private func getScaleFactor(for assetName: String, node: SCNNode) -> Float {
        // Get current bounding box
        let (minBounds, maxBounds) = node.boundingBox
        let size = SCNVector3(maxBounds.x - minBounds.x, maxBounds.y - minBounds.y, maxBounds.z - minBounds.z)
        let currentWidth = max(size.x, size.z)
        guard currentWidth > 0 else { return 1.0 }

        // Different scale targets for different assets
        let targetSize: Float
        if assetName == "kitchen" {
            targetSize = 4.0  // 4m width for kitchen
        } else if assetName == "gun" {
            targetSize = 0.2  // 0.2m (20cm) for gun
        } else {
            targetSize = 1.0
        }

        let scaleFactor = targetSize / currentWidth
        print("📏 Scaling \(assetName): current width \(currentWidth)m -> target \(targetSize)m (factor: \(scaleFactor))")
        return scaleFactor
    }

    private func calculateGunTransform(kitchenTransform: simd_float4x4, relativeOffset: SIMD3<Float>) -> simd_float4x4 {
        // Extract kitchen position
        let kitchenPosition = SIMD3<Float>(
            kitchenTransform.columns.3.x,
            kitchenTransform.columns.3.y,
            kitchenTransform.columns.3.z
        )

        // Extract kitchen rotation matrix (3x3 upper-left portion)
        let rotationMatrix = simd_float3x3(
            SIMD3<Float>(kitchenTransform.columns.0.x, kitchenTransform.columns.0.y, kitchenTransform.columns.0.z),
            SIMD3<Float>(kitchenTransform.columns.1.x, kitchenTransform.columns.1.y, kitchenTransform.columns.1.z),
            SIMD3<Float>(kitchenTransform.columns.2.x, kitchenTransform.columns.2.y, kitchenTransform.columns.2.z)
        )

        // Rotate the relative offset by the kitchen's rotation
        let rotatedOffset = rotationMatrix * relativeOffset

        // Calculate gun's world position
        let gunPosition = kitchenPosition + rotatedOffset

        // Create gun transform with same rotation as kitchen, but at calculated position
        var gunTransform = kitchenTransform
        gunTransform.columns.3 = SIMD4<Float>(gunPosition.x, gunPosition.y, gunPosition.z, 1.0)

        return gunTransform
    }

    private func placeAssets() {
        print("\n🔧 === PLACING ASSETS ===")
        print("📋 Available asset transforms: \(assetTransforms.keys.sorted())")

        // Load kitchen
        if let kitchenTransform = assetTransforms["kitchen"] {
            print("🏠 Loading kitchen...")
            loadAsset(named: "kitchen", at: kitchenTransform)
        } else {
            print("⚠️ No kitchen to load. Use Testing Setup to place kitchen first.")
        }

        // Load gun at relative position to kitchen
        if let gunTransform = assetTransforms["gun"] {
            print("🔫 Loading gun from saved transform...")
            let gunPos = gunTransform.columns.3
            print("   Gun position: (\(gunPos.x), \(gunPos.y), \(gunPos.z))")
            loadAsset(named: "gun", at: gunTransform)
        } else if let kitchenTransform = assetTransforms["kitchen"] {
            print("🔫 Gun transform not saved, calculating from kitchen position...")
            // Calculate gun position if not saved
            let relativeOffset = SIMD3<Float>(1.340, -0.274, 0.762)
            print("   Using relative offset: (\(relativeOffset.x), \(relativeOffset.y), \(relativeOffset.z))")
            let gunTransform = calculateGunTransform(kitchenTransform: kitchenTransform, relativeOffset: relativeOffset)
            let gunPos = gunTransform.columns.3
            print("   Calculated gun position: (\(gunPos.x), \(gunPos.y), \(gunPos.z))")
            loadAsset(named: "gun", at: gunTransform)
        } else {
            print("⚠️ Cannot load gun - no kitchen transform available")
        }
        print("=== ASSET PLACEMENT COMPLETE ===\n")
    }
}

