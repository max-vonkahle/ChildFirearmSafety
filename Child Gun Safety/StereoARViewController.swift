//
//  StereoARViewController.swift
//  Child Gun Safety
//
//  Created by Max on 10/5/25.
//


// StereoARViewController.swift
import UIKit
import ARKit
import SceneKit

final class StereoARViewController: UIViewController, ARSessionDelegate {
    private let session = ARSession()
    private let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    private let scene = SCNScene()
    private let baseCameraNode = SCNNode()
    private let leftEye = SCNNode()
    private let rightEye = SCNNode()
    private var displayLink: CADisplayLink?
    private var config = StereoConfig()

    // public init with custom config if you want
    convenience init(config: StereoConfig) {
        self.init(nibName: nil, bundle: nil)
        self.config = config
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isOpaque = true
        view.backgroundColor = .black

        // Scene/camera setup
        baseCameraNode.camera = SCNCamera()
        baseCameraNode.camera?.usesOrthographicProjection = false

        leftEye.camera = SCNCamera()
        rightEye.camera = SCNCamera()

        // Don’t let SceneKit auto-manage exposure here
        [baseCameraNode, leftEye, rightEye].forEach {
            $0.camera?.wantsHDR = false
            $0.camera?.wantsExposureAdaptation = false
        }

        scene.rootNode.addChildNode(baseCameraNode)
        renderer.scene = scene
        renderer.pointOfView = baseCameraNode

        // Example content to prove stereo (a simple box 1.5 m ahead)
        let box = SCNNode(geometry: SCNBox(width: 0.2, height: 0.2, length: 0.2, chamferRadius: 0.01))
        box.position = SCNVector3(0, 0, -1.5)
        scene.rootNode.addChildNode(box)

        // ARKit
        session.delegate = self
        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = [.horizontal]
        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let link = CADisplayLink(target: self, selector: #selector(drawFrame))
        link.add(to: .main, forMode: .default)
        displayLink = link
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
        session.pause()
    }

    // Keep camera aligned to ARKit head pose
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // World transform -> SceneKit (right-handed) uses the same basis with -Z forward
        baseCameraNode.simdTransform = frame.camera.transform
    }

    @objc private func drawFrame() {
        guard let frame = session.currentFrame else { return }
        guard let drawable = (view.layer as? CAMetalLayer)?.nextDrawable() else {
            ensureMetalLayer()
            return
        }

        let scale = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        let w = view.bounds.width * scale
        let h = view.bounds.height * scale
        let halfW = w / 2.0

        // Configure per-eye projections based on the ARCamera intrinsics & half viewport
        let orientation: UIInterfaceOrientation = .landscapeRight  // lock orientation for viewer
        let viewportHalf = CGSize(width: halfW, height: h)

        let leftProj  = frame.camera.projectionMatrix(for: orientation,
                                                      viewportSize: viewportHalf,
                                                      zNear: CGFloat(config.zNear),
                                                      zFar:  CGFloat(config.zFar))
        let rightProj = frame.camera.projectionMatrix(for: orientation,
                                                      viewportSize: viewportHalf,
                                                      zNear: CGFloat(config.zNear),
                                                      zFar:  CGFloat(config.zFar))

        // Offset eyes in camera (view) space by ±ipd/2 along +X / -X
        let ipd = config.ipdMeters
        leftEye.simdTransform  = baseCameraNode.simdTransform
        rightEye.simdTransform = baseCameraNode.simdTransform

        // Apply local translation in camera space
        leftEye.simdLocalTranslate(by: SIMD3<Float>(-ipd/2, 0, 0))
        rightEye.simdLocalTranslate(by: SIMD3<Float>( ipd/2, 0, 0))

        leftEye.camera?.projectionTransform  = SCNMatrix4(leftProj)
        rightEye.camera?.projectionTransform = SCNMatrix4(rightProj)

        // Prepare Metal render pass that covers whole screen; we’ll render two viewports
        guard let cmdQueue = renderer.device?.makeCommandQueue(),
              let cmdBuf = cmdQueue.makeCommandBuffer(),
              let passDesc = currentPassDescriptor(for: drawable) else { return }

        // Render LEFT eye into left half viewport
        renderer.pointOfView = leftEye
        renderer.render(atTime: CACurrentMediaTime(),
                        viewport: CGRect(x: 0, y: 0, width: Int(halfW), height: Int(h)),
                        commandBuffer: cmdBuf,
                        passDescriptor: passDesc)

        // Render RIGHT eye into right half viewport
        renderer.pointOfView = rightEye
        renderer.render(atTime: CACurrentMediaTime(),
                        viewport: CGRect(x: Int(halfW), y: 0, width: Int(halfW), height: Int(h)),
                        commandBuffer: cmdBuf,
                        passDescriptor: passDesc)

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    private func currentPassDescriptor(for drawable: CAMetalDrawable) -> MTLRenderPassDescriptor? {
        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = drawable.texture
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].storeAction = .store
        desc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        return desc
    }

    private func ensureMetalLayer() {
        guard !(view.layer is CAMetalLayer) else { return }
        let metalLayer = CAMetalLayer()
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.frame = view.layer.bounds
        view.layer.addSublayer(metalLayer)
        view.layer.setNeedsDisplay()
    }

    // Expose session for external AR content anchoring if needed
    var arSession: ARSession { session }
}