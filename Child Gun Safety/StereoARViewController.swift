//
//  StereoARViewController.swift
//  Child Gun Safety
//
//  Created by Max on 10/5/25.
//

import UIKit
import ARKit
import SceneKit
import CoreImage

final class StereoARViewController: UIViewController, ARSessionDelegate {
    // AR session
    private let session = ARSession()

    // SceneKit scene and camera rig
    private let scene = SCNScene()
    private let baseCameraNode = SCNNode()
    private let leftEye = SCNNode()
    private let rightEye = SCNNode()

    // Passthrough views (camera images)
    private var leftImageView: UIImageView!
    private var rightImageView: UIImageView!

    // SceneKit views (overlays for 3D content)
    private var leftSCNView: SCNView!
    private var rightSCNView: SCNView!

    // Cardboard mask  reticle (UIKit, like ARFun)
    private var maskView: UIView!
    private var reticleView: UIView!

    // Reuse CIContext for performance
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var isProcessingFrame = false

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

        // --- Camera passthrough image views ---
        leftImageView = UIImageView()
        leftImageView.contentMode = .scaleAspectFill
        leftImageView.clipsToBounds = true
        view.addSubview(leftImageView)

        rightImageView = UIImageView()
        rightImageView.contentMode = .scaleAspectFill
        rightImageView.clipsToBounds = true
        view.addSubview(rightImageView)

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

        // Example 3D content (box in front) – replace with your AR content
        let boxGeometry = SCNBox(width: 0.1, height: 0.1, length: 0.1, chamferRadius: 0.0)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.blue
        boxGeometry.materials = [material]
        let boxNode = SCNNode(geometry: boxGeometry)
        boxNode.position = SCNVector3(0, 0, -0.5)
        scene.rootNode.addChildNode(boxNode)

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

        // Left/right halves for camera images
        leftImageView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        rightImageView.frame = CGRect(x: width, y: 0, width: width, height: height)

        // SceneKit views sit on top of the images
        leftSCNView.frame = leftImageView.frame
        rightSCNView.frame = rightImageView.frame

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

    // Keep camera aligned to ARKit head pose + update stereo camera images
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        print("StereoARViewController didUpdate session =", session)
        // Update head position immediately (fast)
        baseCameraNode.simdTransform = frame.camera.transform

        // Skip frame if still processing previous one
        if isProcessingFrame { return }
        isProcessingFrame = true

        // Copy out orientation & viewport info
        let interfaceOrientation = view.window?.windowScene?.interfaceOrientation ?? .landscapeRight
        let viewportSize = view.bounds.size
        let stereoOffset = self.stereoOffset
        let cameraImageScale = self.cameraImageScale

        // Do ALL work with the frame's pixel buffer synchronously inside this method
        autoreleasepool {
            let pixelBuffer = frame.capturedImage
            var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

            // Apply proper orientation transform using ARKit's displayTransform
            let displayTransform = frame.displayTransform(for: interfaceOrientation, viewportSize: viewportSize)
            ciImage = ciImage.transformed(by: displayTransform)

            let imageWidth = ciImage.extent.width
            let imageHeight = ciImage.extent.height

            // Horizontal stereo offset in pixels
            let offsetPixels = imageWidth * stereoOffset

            // Left eye: sees more of the LEFT side of the image
            let leftCropRect = CGRect(
                x: 0,
                y: 0,
                width: imageWidth - offsetPixels,
                height: imageHeight
            )
            let leftImage = ciImage.cropped(to: leftCropRect)

            // Right eye: sees more of the RIGHT side of the image
            let rightCropRect = CGRect(
                x: offsetPixels,
                y: 0,
                width: imageWidth - offsetPixels,
                height: imageHeight
            )
            let rightImage = ciImage.cropped(to: rightCropRect)

            // Convert to CGImages using reusable context
            guard let leftCGImage = ciContext.createCGImage(leftImage, from: leftImage.extent),
                  let rightCGImage = ciContext.createCGImage(rightImage, from: rightImage.extent) else {
                isProcessingFrame = false
                return
            }

            let leftUIImage = UIImage(cgImage: leftCGImage, scale: cameraImageScale, orientation: .up)
            let rightUIImage = UIImage(cgImage: rightCGImage, scale: cameraImageScale, orientation: .up)

            // Update on main thread (we're already on main, but keep this to be explicit)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.leftImageView.image = leftUIImage
                self.rightImageView.image = rightUIImage
                self.isProcessingFrame = false
            }
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
}
