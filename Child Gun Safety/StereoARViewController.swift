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

@MainActor
final class StereoARViewController: UIViewController, ARSessionDelegate {
    private let session = ARSession()
    private let scene = SCNScene()
    private let baseCameraNode = SCNNode()
    private let leftEye = SCNNode()
    private let rightEye = SCNNode()
    private var displayLink: CADisplayLink?
    private var config = StereoConfig()

    // Passthrough views (behind SCNViews for camera feed)
    private let leftImageView = UIImageView()
    private let rightImageView = UIImageView()

    // SceneKit views for stereo rendering (transparent, on top of image views)
    private let leftSCNView = SCNView()
    private let rightSCNView = SCNView()

    // public init with custom config if you want
    convenience init(config: StereoConfig) {
        self.init(nibName: nil, bundle: nil)
        self.config = config
    }

    override func loadView() {
        view = UIView(frame: .zero)
        view.backgroundColor = .black
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Setup passthrough image views (full half-screen, aspect fill)
        leftImageView.contentMode = .scaleAspectFill
        leftImageView.clipsToBounds = true
        rightImageView.contentMode = .scaleAspectFill
        rightImageView.clipsToBounds = true
        view.addSubview(leftImageView)
        view.addSubview(rightImageView)

        // Setup SCNViews (transparent background, auto-render)
        leftSCNView.backgroundColor = .clear
        leftSCNView.rendersContinuously = true  // Ensures smooth rendering
        leftSCNView.isPlaying = true
        rightSCNView.backgroundColor = .clear
        rightSCNView.rendersContinuously = true
        rightSCNView.isPlaying = true
        view.addSubview(leftSCNView)
        view.addSubview(rightSCNView)

        // Scene/camera setup (same as before)
        baseCameraNode.camera = SCNCamera()
        baseCameraNode.camera?.usesOrthographicProjection = false

        leftEye.camera = SCNCamera()
        rightEye.camera = SCNCamera()

        // Don’t let SceneKit auto-manage exposure here
        [baseCameraNode, leftEye, rightEye].forEach {
            $0.camera?.wantsHDR = false
            $0.camera?.wantsExposureAdaptation = false
        }

        baseCameraNode.addChildNode(leftEye)
        baseCameraNode.addChildNode(rightEye)
        scene.rootNode.addChildNode(baseCameraNode)

        // Example content to prove stereo (a simple box 1.5 m ahead) - replace with your AR content
        let box = SCNNode(geometry: SCNBox(width: 0.2, height: 0.2, length: 0.2, chamferRadius: 0.01))
        box.position = SCNVector3(0, 0, -1.5)
        scene.rootNode.addChildNode(box)

        // Attach scene and POV to SCNViews
        leftSCNView.scene = scene
        leftSCNView.pointOfView = leftEye
        rightSCNView.scene = scene
        rightSCNView.pointOfView = rightEye

        // ARKit setup (same as before)
        session.delegate = self
        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = [.horizontal]
        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let halfWidth = view.bounds.width / 2
        leftImageView.frame = CGRect(x: 0, y: 0, width: halfWidth, height: view.bounds.height)
        rightImageView.frame = CGRect(x: halfWidth, y: 0, width: halfWidth, height: view.bounds.height)
        leftSCNView.frame = leftImageView.frame
        rightSCNView.frame = rightImageView.frame
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let link = CADisplayLink(target: self, selector: #selector(updateFrame))
        link.add(to: .main, forMode: .default)
        displayLink = link
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
        session.pause()
    }

    // Keep camera aligned to ARKit head pose (same as before)
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        autoreleasepool {
            // World transform -> SceneKit (right-handed) uses the same basis with -Z forward
            baseCameraNode.simdTransform = frame.camera.transform
        }
    }

    @objc private func updateFrame() {
        autoreleasepool {
            guard let frame = session.currentFrame else { return }

            let orientation = view.window?.windowScene?.interfaceOrientation ?? .landscapeRight
            let halfWidth = view.bounds.width / 2
            let viewportHalf = CGSize(width: halfWidth, height: view.bounds.height)

            // Configure per-eye projections based on the ARCamera intrinsics & half viewport (same as before)
            let leftProj = frame.camera.projectionMatrix(for: orientation,
                                                         viewportSize: viewportHalf,
                                                         zNear: CGFloat(config.zNear),
                                                         zFar: CGFloat(config.zFar))
            let rightProj = frame.camera.projectionMatrix(for: orientation,
                                                          viewportSize: viewportHalf,
                                                          zNear: CGFloat(config.zNear),
                                                          zFar: CGFloat(config.zFar))

            // Offset eyes in camera (view) space by ±ipd/2 along +X / -X (same as before)
            let ipd = config.ipdMeters
            leftEye.simdPosition = SIMD3<Float>(-ipd / 2, 0, 0)
            rightEye.simdPosition = SIMD3<Float>(ipd / 2, 0, 0)

            leftEye.camera?.projectionTransform = SCNMatrix4(leftProj)
            rightEye.camera?.projectionTransform = SCNMatrix4(rightProj)

            // Update passthrough images (centered crop matching half aspect, duplicated for both eyes)
            updateCameraBackground(from: frame, orientation: orientation)
        }
    }

    private func updateCameraBackground(from frame: ARFrame, orientation: UIInterfaceOrientation) {
        let cgOrientation = exifOrientation(for: orientation)
        var image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(cgOrientation)

        let halfWidth = view.bounds.width / 2
        let viewportHalf = CGSize(width: halfWidth, height: view.bounds.height)
        let halfAspect = viewportHalf.width / viewportHalf.height
        let imageExtent = image.extent
        let imageAspect = imageExtent.width / imageExtent.height

        // Crop to center, matching half aspect (preserves center for both eyes)
        var cropRect: CGRect
        if imageAspect > halfAspect {
            // Crop sides (image wider than half aspect)
            let cropWidth = imageExtent.height * halfAspect
            let xOffset = (imageExtent.width - cropWidth) / 2
            cropRect = CGRect(x: xOffset, y: 0, width: cropWidth, height: imageExtent.height)
        } else {
            // Crop top/bottom (image taller)
            let cropHeight = imageExtent.width / halfAspect
            let yOffset = (imageExtent.height - cropHeight) / 2
            cropRect = CGRect(x: 0, y: yOffset, width: imageExtent.width, height: cropHeight)
        }
        image = image.cropped(to: cropRect)

        // Normalize origin and convert to UIImage (shared for both eyes)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
        let uiImage = UIImage(ciImage: image)

        leftImageView.image = uiImage
        rightImageView.image = uiImage
    }

    private func exifOrientation(for orientation: UIInterfaceOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .down
        case .landscapeRight: return .up
        default: return .up
        }
    }

    // Expose session for external AR content anchoring if needed (same as before)
    var arSession: ARSession { session }

    func apply(config newConfig: StereoConfig) {
        config = newConfig
    }
}
