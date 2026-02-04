//
//  TestingOrchestratorView.swift
//  Child Gun Safety
//
//  Virtual kitchen testing environment for gun safety assessment
//

import SwiftUI

struct TestingOrchestratorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coach = VoiceCoach(promptKey: "testingPrompt")
    @AppStorage("cardboardMode") private var cardboardMode = false

    @State private var showStartPrompt = false
    @State private var showCamera = false
    @State private var sceneReady = false
    @State private var selectedRoomId: String? = nil
    @State private var roomNames: [String] = RoomLibrary.savedTestingRooms()

    var body: some View {
        Group {
            if selectedRoomId == nil {
                // Show room picker
                RoomPickerView(
                    title: "Choose a Testing Room",
                    emptyMessage: "Create a testing room first using Testing Setup.",
                    rooms: roomNames,
                    onPick: { name in
                        selectedRoomId = name
                        print("📍 Selected testing room: \(name)")
                    },
                    onDelete: { name in
                        RoomLibrary.deleteTestingRoom(name)
                        roomNames = RoomLibrary.savedTestingRooms()
                    }
                )
                .onAppear {
                    roomNames = RoomLibrary.savedTestingRooms()
                }
            } else {
                testingScene
            }
        }
    }

    private var testingScene: some View {
        Group {
            ZStack {
                if cardboardMode {
                    TestingStereoARContainer(
                        roomId: selectedRoomId,
                        onSceneReady: {
                            sceneReady = true
                            showStartPrompt = true
                        }
                    )
                    .ignoresSafeArea()
                    .scaleEffect(0.98)
                    .ignoresSafeArea()
                    .opacity(showCamera ? 1 : 0)
                    .onDisappear {
                        coach.stopSession()
                    }
                } else {
                    TestingARView(
                        roomId: selectedRoomId,
                        onSceneReady: {
                            sceneReady = true
                            showStartPrompt = true
                        },
                        onExit: {
                            coach.stopSession()
                            dismiss()
                        }
                    )
                    .opacity(showCamera ? 1 : 0)
                    .onDisappear {
                        coach.stopSession()
                    }
                }

                // Black background until camera reveals
                if !showCamera {
                    Color.black
                        .ignoresSafeArea()
                }

                // Start prompt
                if showStartPrompt {
                    StartTestingPromptView {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showStartPrompt = false
                            showCamera = true
                        }
                        coach.startSession()
                    }
                }

                // Microphone state indicator (top-left)
                if showCamera {
                    VStack {
                        MicIndicatorView(coach: coach)
                        Spacer()
                    }
                }

            }
            .overlay(alignment: .topTrailing) {
                if showCamera {
                    Button {
                        coach.stopSession()
                        selectedRoomId = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28, weight: .bold))
                            .padding(16)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Exit to Room Picker")
                    .padding(.top, 44)
                    .padding(.trailing, 16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
        }
    }
}

// MARK: - Testing AR View
import ARKit
import RealityKit

struct TestingARView: UIViewControllerRepresentable {
    let roomId: String?
    let onSceneReady: () -> Void
    let onExit: () -> Void
    @AppStorage("cardboardMode") private var cardboardMode = false

    func makeUIViewController(context: Context) -> TestingARViewController {
        let vc = TestingARViewController()
        vc.roomId = roomId
        vc.onSceneReady = onSceneReady
        vc.onExit = onExit
        vc.cardboardMode = cardboardMode
        return vc
    }

    func updateUIViewController(_ uiViewController: TestingARViewController, context: Context) {
        uiViewController.cardboardMode = cardboardMode
    }
}

// Wraps StereoARViewController in testing mode — loads the testing room's
// world map and places kitchen + gun via SceneKit, matching the Metal
// passthrough + stereo split used by training.
struct TestingStereoARContainer: UIViewControllerRepresentable {
    let roomId: String?
    let onSceneReady: () -> Void

    func makeUIViewController(context: Context) -> StereoARViewController {
        let vc = StereoARViewController(config: StereoConfig())
        vc.testingRoomId = roomId
        vc.onTestingSceneReady = onSceneReady
        return vc
    }

    func updateUIViewController(_ vc: StereoARViewController, context: Context) {}
}

final class TestingARViewController: UIViewController {
    var roomId: String?
    var onSceneReady: (() -> Void)?
    var onExit: (() -> Void)?
    var cardboardMode: Bool = false

    private var arView: ARView!
    private var assetTransforms: [String: simd_float4x4] = [:]
    private var worldMapLoaded = false
    private var relocalizationTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()

        print("\n🎬 TestingARViewController viewDidLoad")
        print("📋 roomId: \(roomId ?? "nil")")

        setupARView()
        loadRoomData()

        // Start timer - if relocalization doesn't happen in 10 seconds, place assets anyway
        relocalizationTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            guard let self = self, !self.worldMapLoaded else { return }
            print("⏱️ Relocalization timeout - placing assets anyway")
            self.worldMapLoaded = true
            self.placeAssets()
            self.onSceneReady?()
        }
    }

    private func setupARView() {
        arView = ARView(frame: view.bounds)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(arView)

        // Session delegate to know when relocalization completes
        arView.session.delegate = self

        print("✅ ARView created")
    }

    private func loadRoomData() {
        guard let roomId = roomId else {
            print("⚠️ No roomId provided")
            startDefaultSession()
            return
        }

        guard let roomData = RoomLibrary.loadTestingRoom(roomId: roomId) else {
            print("⚠️ Failed to load room data, starting default session")
            startDefaultSession()
            return
        }

        print("✅ Loaded testing room data")
        assetTransforms = roomData.assets

        // Configure AR session with the loaded world map
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        config.initialWorldMap = roomData.worldMap

        // Enable occlusion
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        }

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        print("✅ AR session started with saved world map")
        print("   World map has \(roomData.worldMap.anchors.count) anchors")
    }

    private func startDefaultSession() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        }

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }

        arView.session.run(config)
        print("✅ AR session started (default - no world map)")

        // Place assets immediately if we have transforms
        if !assetTransforms.isEmpty {
            placeAssets()
        }
    }

    private func placeAssets() {
        print("\n🔧 === PLACING ASSETS IN AR ===")

        // Load and place kitchen
        if let kitchenTransform = assetTransforms["kitchen"] {
            loadAsset(named: "kitchen", at: kitchenTransform)
        }

        // ALWAYS calculate gun position relative to kitchen's current position
        // (Don't use saved gun transform since world coordinates can shift during relocalization)
        if let kitchenTransform = assetTransforms["kitchen"] {
            let relativeOffset = SIMD3<Float>(0.5823, 0.8431, -2.5297)
            let gunTransform = calculateGunTransform(kitchenTransform: kitchenTransform, relativeOffset: relativeOffset)
            loadAsset(named: "gun", at: gunTransform, scale: 0.2)
            print("🔫 Gun calculated relative to kitchen at offset: \(relativeOffset)")
        }

        print("=== ASSET PLACEMENT COMPLETE ===\n")
    }

    private func loadAsset(named assetName: String, at transform: simd_float4x4, scale targetSize: Float? = nil) {
        guard let assetURL = Bundle.main.url(forResource: assetName, withExtension: "usdz") else {
            print("⚠️ \(assetName).usdz not found in bundle")
            return
        }

        do {
            let model = try ModelEntity.loadModel(contentsOf: assetURL)

            // Scale the model if a target size is provided
            if let targetSize = targetSize {
                let bounds = model.visualBounds(relativeTo: nil)
                let size = bounds.extents
                let currentWidth = max(size.x, size.z)
                if currentWidth > 0 {
                    let scaleFactor = targetSize / currentWidth
                    model.scale *= SIMD3<Float>(repeating: scaleFactor)
                    print("📏 Scaled \(assetName): \(currentWidth)m -> \(targetSize)m (factor: \(scaleFactor))")
                }
            }

            // Generate collision shapes
            model.generateCollisionShapes(recursive: true)

            // Create anchor at saved position
            let anchor = AnchorEntity(world: transform)
            anchor.addChild(model)
            arView.scene.addAnchor(anchor)

            // Rotate gun to match setup orientation
            if assetName == "gun" {
                let rotX = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
                let rotZ = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
                model.orientation = rotZ * rotX
            }

            let pos = transform.columns.3
            print("✅ Placed \(assetName) at (\(pos.x), \(pos.y), \(pos.z))")
        } catch {
            print("❌ Failed to load \(assetName): \(error)")
        }
    }

    private func calculateGunTransform(kitchenTransform: simd_float4x4, relativeOffset: SIMD3<Float>) -> simd_float4x4 {
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
}

// MARK: - ARSession Delegate
extension TestingARViewController: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Check if world mapping is in a good state and we haven't placed assets yet
        guard !worldMapLoaded else { return }

        // Log mapping status periodically (every 30 frames)
        if frame.timestamp.truncatingRemainder(dividingBy: 1.0) < 0.033 {
            print("🗺️ World mapping status: \(frame.worldMappingStatus.debugDescription)")
        }

        switch frame.worldMappingStatus {
        case .mapped, .extending:
            // World map is ready - place assets
            worldMapLoaded = true
            relocalizationTimer?.invalidate()
            print("✅ World map relocalized successfully - placing assets now!")

            DispatchQueue.main.async { [weak self] in
                self?.placeAssets()
                self?.onSceneReady?()
            }
        case .limited:
            // Still relocalizing - this is normal initially
            break
        case .notAvailable:
            print("⚠️ World mapping not available")
        @unknown default:
            break
        }
    }
}

// Helper for debug description
extension ARFrame.WorldMappingStatus {
    var debugDescription: String {
        switch self {
        case .notAvailable: return "Not Available"
        case .limited: return "Limited (relocalizing...)"
        case .extending: return "Extending"
        case .mapped: return "Mapped"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Start Prompt

// Start prompt view for testing
struct StartTestingPromptView: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checklist.checked")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("Safety Testing")
                .font(.largeTitle)
                .bold()

            Text("You'll practice what you've learned\nin a virtual kitchen environment")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                onStart()
            } label: {
                Text("Touch to Start")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: 280)
                    .padding()
                    .background(Color.green)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.top, 8)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 40)
    }
}
