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
import Metal
import QuartzCore
import CoreImage
import ImageIO

@MainActor
final class StereoARViewController: UIViewController, ARSessionDelegate {
    private final class MetalHostView: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }
    }

    private let device: MTLDevice = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device.")
        }
        return device
    }()
    private let session = ARSession()
    private let scene = SCNScene()
    private let baseCameraNode = SCNNode()
    private let leftEye = SCNNode()
    private let rightEye = SCNNode()
    private var displayLink: CADisplayLink?
    private var config = StereoConfig()

    private lazy var renderer: SCNRenderer = {
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        return renderer
    }()

    private lazy var commandQueue: MTLCommandQueue? = device.makeCommandQueue()
    private lazy var ciContext = CIContext(mtlDevice: device)
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private var metalLayer: CAMetalLayer? {
        view.layer as? CAMetalLayer
    }

    // public init with custom config if you want
    convenience init(config: StereoConfig) {
        self.init(nibName: nil, bundle: nil)
        self.config = config
    }

    override func loadView() {
        let view = MetalHostView(frame: .zero)
        view.isOpaque = true
        view.backgroundColor = .black
        (view.layer as? CAMetalLayer)?.device = device
        (view.layer as? CAMetalLayer)?.pixelFormat = .bgra8Unorm
        (view.layer as? CAMetalLayer)?.framebufferOnly = true
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()

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

        baseCameraNode.addChildNode(leftEye)
        baseCameraNode.addChildNode(rightEye)
        scene.rootNode.addChildNode(baseCameraNode)

        // Example content to prove stereo (a simple box 1.5 m ahead)
        let box = SCNNode(geometry: SCNBox(width: 0.2, height: 0.2, length: 0.2, chamferRadius: 0.01))
        box.position = SCNVector3(0, 0, -1.5)
        scene.rootNode.addChildNode(box)

        renderer.pointOfView = baseCameraNode

        // ARKit
        session.delegate = self
        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = [.horizontal]
        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let metalLayer else { return }
        let scale = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        metalLayer.frame = view.bounds
        metalLayer.drawableSize = CGSize(width: view.bounds.width * scale,
                                         height: view.bounds.height * scale)
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
        autoreleasepool {
            // World transform -> SceneKit (right-handed) uses the same basis with -Z forward
            baseCameraNode.simdTransform = frame.camera.transform
        }
    }

    @objc private func drawFrame() {
        autoreleasepool {
            guard let frame = session.currentFrame,
                  let metalLayer,
                  let drawable = metalLayer.nextDrawable(),
                  let commandQueue else { return }

            let orientation = view.window?.windowScene?.interfaceOrientation ?? .landscapeRight
            let scale = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
            let drawableSize = metalLayer.drawableSize == .zero
                ? CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
                : metalLayer.drawableSize

            if metalLayer.drawableSize == .zero {
                metalLayer.drawableSize = drawableSize
            }

            let halfWidth = drawableSize.width * 0.5

            // Configure per-eye projections based on the ARCamera intrinsics & half viewport
            let viewportHalf = CGSize(width: halfWidth, height: drawableSize.height)

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
            leftEye.simdPosition = SIMD3<Float>(-ipd / 2, 0, 0)
            rightEye.simdPosition = SIMD3<Float>(ipd / 2, 0, 0)

            leftEye.camera?.projectionTransform  = SCNMatrix4(leftProj)
            rightEye.camera?.projectionTransform = SCNMatrix4(rightProj)

            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
            commandBuffer.label = "StereoARFrame"

            renderCameraBackground(from: frame,
                                   commandBuffer: commandBuffer,
                                   drawable: drawable,
                                   drawableSize: drawableSize,
                                   orientation: orientation)

            let passDesc = currentPassDescriptor(for: drawable)
            passDesc.colorAttachments[0].loadAction = .load

            let timestamp = CACurrentMediaTime()

            // Render LEFT eye into left half viewport
            renderer.pointOfView = leftEye
            renderer.render(atTime: timestamp,
                            viewport: CGRect(x: 0,
                                             y: 0,
                                             width: halfWidth,
                                             height: drawableSize.height),
                            commandBuffer: commandBuffer,
                            passDescriptor: passDesc)

            // Ensure the second eye does not clear the buffer the first eye just rendered into
            passDesc.colorAttachments[0].loadAction = .load

            // Render RIGHT eye into right half viewport
            renderer.pointOfView = rightEye
            renderer.render(atTime: timestamp,
                            viewport: CGRect(x: halfWidth,
                                             y: 0,
                                             width: halfWidth,
                                             height: drawableSize.height),
                            commandBuffer: commandBuffer,
                            passDescriptor: passDesc)

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    private func currentPassDescriptor(for drawable: CAMetalDrawable) -> MTLRenderPassDescriptor {
        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = drawable.texture
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].storeAction = .store
        desc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        return desc
    }

    private func renderCameraBackground(from frame: ARFrame,
                                        commandBuffer: MTLCommandBuffer,
                                        drawable: CAMetalDrawable,
                                        drawableSize: CGSize,
                                        orientation: UIInterfaceOrientation) {
        let orientation = exifOrientation(for: orientation)
        var image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(orientation)

        // Scale and crop to fill the drawable while preserving aspect ratio
        let scale = max(drawableSize.width / image.extent.width,
                        drawableSize.height / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let cropRect = CGRect(x: image.extent.midX - drawableSize.width * 0.5,
                              y: image.extent.midY - drawableSize.height * 0.5,
                              width: drawableSize.width,
                              height: drawableSize.height)
        image = image.cropped(to: cropRect)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x,
                                                        y: -image.extent.origin.y))

        ciContext.render(image,
                         to: drawable.texture,
                         commandBuffer: commandBuffer,
                         bounds: CGRect(origin: .zero, size: drawableSize),
                         colorSpace: colorSpace)
    }

    private func exifOrientation(for orientation: UIInterfaceOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .portrait:
            return .right
        case .portraitUpsideDown:
            return .left
        case .landscapeLeft:
            return .down
        case .landscapeRight:
            return .up
        default:
            return .up
        }
    }

    // Expose session for external AR content anchoring if needed
    var arSession: ARSession { session }

    func apply(config newConfig: StereoConfig) {
        config = newConfig
    }
}
