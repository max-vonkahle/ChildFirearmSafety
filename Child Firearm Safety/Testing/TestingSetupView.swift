//
//  TestingSetupView.swift
//  Child Firearm Safety
//
//  Setup flow for creating testing rooms by selecting a back wall
//

import SwiftUI
import ARKit
import RealityKit
import simd

enum TestingSetupMode { case create, load }

// MARK: - Shared UI State

final class TestingSetupState: ObservableObject {
    @Published var hasKitchen = false
    @Published var uiState = SetupUIState()

    // Actions wired by the VC at viewDidLoad
    var placeKitchenAction: (() -> Void)?
    var clearAction:        (() -> Void)?
}

// MARK: - Top-level View

struct TestingSetupView: View {
    let mode: TestingSetupMode

    @State private var selectedRoom: String? = nil
    @State private var roomNames: [String] = RoomLibrary.savedTestingRooms()

    @State private var showSaveSheet      = false
    @State private var roomId             = ""
    @State private var showScanMoreAlert  = false
    @State private var saveErrorMessage   = ""

    @StateObject private var setupState = TestingSetupState()
    @Environment(\.dismiss) private var dismiss

    // Control visibility (tap to show/hide)
    @State private var showControls = false
    @State private var autoHideTask: Task<Void, Never>? = nil

    var body: some View {
        Group {
            if mode == .load && selectedRoom == nil {
                RoomPickerView(
                    title: "Load Testing Room",
                    rooms: roomNames,
                    onPick: { name in
                        selectedRoom = name
                    },
                    onDelete: { name in
                        RoomLibrary.deleteTestingRoom(name)
                        roomNames = RoomLibrary.savedTestingRooms()
                    }
                )
                .onAppear { roomNames = RoomLibrary.savedTestingRooms() }
            } else if mode == .create || selectedRoom != nil {
                arScene
            }
        }
        .onChange(of: showSaveSheet) { _, isShowing in
            if !isShowing {
                roomNames = RoomLibrary.savedTestingRooms()
            }
        }
    }

    // MARK: - AR Scene + SwiftUI Overlays

    private var arScene: some View {
        ZStack {
            TestingWallSelectorView(
                roomId: mode == .load ? selectedRoom : nil,
                state: setupState,
                onExit: { dismiss() },
                onSaveError: { error in
                    saveErrorMessage = error
                    showScanMoreAlert = true
                }
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    handleTap()
                }
            )

            VStack {
                if mode == .create {
                    SetupInstructionOverlay(
                        state: setupState.uiState,
                        steps: [
                            "Move device around to scan the area",
                            "Tap screen to show controls",
                            "Tap Place to add kitchen on the floor",
                            "Tap wall behind kitchen to anchor it",
                            "Save room when finished"
                        ]
                    )
                }

                Spacer()

                if showControls {
                    controlsOverlay
                }
            }

            if showControls {
                VStack {
                    HStack {
                        Spacer()
                        exitButton
                    }
                    Spacer()
                }
            }
        }
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSaveSheet) { saveSheet }
        .alert("Need More Scanning", isPresented: $showScanMoreAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(saveErrorMessage)
        }
        .onDisappear {
            cleanupAutoHide()
        }
    }

    // MARK: - Tap Handling

    private func handleTap() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }
        if showControls {
            scheduleAutoHideControls()
        } else {
            cleanupAutoHide()
        }
    }

    private func scheduleAutoHideControls() {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls = false
            }
            autoHideTask = nil
        }
    }

    private func cleanupAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    // MARK: - Exit button

    private var exitButton: some View {
        Button {
            cleanupAutoHide()
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 28, weight: .bold))
                .padding(16)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Exit")
        .transition(.opacity.combined(with: .scale))
        .padding(.top, 44)
        .padding(.trailing, 16)
    }

    // MARK: - Bottom toolbar

    private var controlsOverlay: some View {
        SetupControlButtons(
            onClear: {
                setupState.clearAction?()
            },
            onPlace: {
                setupState.placeKitchenAction?()
            },
            onSave: {
                showSaveSheet = true
            },
            canSave: setupState.hasKitchen,
            placeLabel: "Place"
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: showControls)
    }

    // MARK: - Save Sheet

    private var saveSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Name this testing room").font(.headline)

                TextField("e.g. my-kitchen", text: $roomId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textFieldStyle(.roundedBorder)

                Spacer()
            }
            .padding()
            .navigationTitle("Save Testing Room")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSaveSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        NotificationCenter.default.post(
                            name: .saveTestingRoom,
                            object: nil,
                            userInfo: ["roomId": trimmed]
                        )
                        showSaveSheet = false
                    }
                    .disabled(roomId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - UIViewControllerRepresentable (AR only, no UI)

struct TestingWallSelectorView: UIViewControllerRepresentable {
    let roomId:      String?
    let state:       TestingSetupState
    let onExit:      () -> Void
    let onSaveError: (String) -> Void

    func makeUIViewController(context: Context) -> TestingWallSelectorViewController {
        let vc = TestingWallSelectorViewController()
        vc.roomId      = roomId
        vc.state       = state
        vc.onExit      = onExit
        vc.onSaveError = onSaveError
        return vc
    }

    func updateUIViewController(_ uiViewController: TestingWallSelectorViewController, context: Context) {}
}

// MARK: - AR View Controller (logic only)

final class TestingWallSelectorViewController: UIViewController {
    var roomId:      String?
    var state:       TestingSetupState!
    var onExit:      (() -> Void)?
    var onSaveError: ((String) -> Void)?

    private var arView: ARView!
    private var backWallAnchor:        AnchorEntity?
    private var selectedWallTransform: simd_float4x4?
    private var selectedWallNormal:    SIMD4<Float>?

    // Placed assets tracking
    private var placedAssets:          [String: ModelEntity]    = [:]
    private var placedAssetTransforms: [String: simd_float4x4] = [:]
    private var placedAssetAnchors:    [String: AnchorEntity]  = [:]

    // Placement state
    private var isArmed:             Bool    = false
    private var selectedAsset:       String? = nil
    private var waitingForKitchenWall: Bool  = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        setupARView()
        setupNotifications()

        // Wire the SwiftUI toolbar buttons back into this VC
        state.placeKitchenAction = { [weak self] in self?.placeKitchen() }
        state.clearAction        = { [weak self] in self?.clearAssets()  }

        if let roomId = roomId {
            loadTestingRoom(roomId)
        }
    }

    private func setupARView() {
        arView = ARView(frame: view.bounds)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(arView)

        let config = ARWorldTrackingConfiguration()
        config.planeDetection      = [.horizontal, .vertical]
        config.environmentTexturing = .automatic

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        }

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation) {
            config.frameSemantics.insert(.personSegmentation)
        }

        arView.session.run(config)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSaveNotification(_:)),
            name: .saveTestingRoom,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSaveError(_:)),
            name: .testingRoomSaveError,
            object: nil
        )
    }

    @objc private func handleSaveError(_ notification: Notification) {
        guard let errorMessage = notification.userInfo?["error"] as? String else { return }
        onSaveError?(errorMessage)
    }

    // MARK: - Toolbar Actions (called via state closures)

    private func placeKitchen() {
        isArmed       = true
        selectedAsset = "kitchen"
    }

    private func clearAssets() {
        for (_, anchor) in placedAssetAnchors {
            arView.scene.removeAnchor(anchor)
        }
        placedAssets.removeAll()
        placedAssetTransforms.removeAll()
        placedAssetAnchors.removeAll()

        state.hasKitchen = false
        // print("✅ Cleared all placed assets")
    }

    // MARK: - Tap Handling

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
        let gunPosition   = kitchenPosition + rotatedOffset

        var gunTransform = kitchenTransform
        gunTransform.columns.3 = SIMD4<Float>(gunPosition.x, gunPosition.y, gunPosition.z, 1.0)
        return gunTransform
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: arView)

        if waitingForKitchenWall {
            handleKitchenWallSelection(at: location)
            return
        }

        guard isArmed, selectedAsset == "kitchen" else { return }

        // Check world mapping status before allowing placement
        if let frame = arView.session.currentFrame {
            let status = frame.worldMappingStatus
            if status == .notAvailable || status == .limited {
                let message: String
                if status == .notAvailable {
                    message = "Cannot place kitchen yet.\n\nPlease move your device slowly around the area to scan surfaces and create spatial anchors."
                } else {
                    message = "Insufficient scanning detected.\n\nMove your device around to scan more of the floor, walls, and surrounding area before placing the kitchen.\n\nMapping status: \(statusDescription(status))"
                }

                DispatchQueue.main.async { [weak self] in
                    self?.showScanningAlert(message: message)
                }
                return
            }
        }

        var targetTransform: simd_float4x4?

        // Kitchen: only allow horizontal floor placement
        let planeResults = arView.raycast(
            from: location,
            allowing: .existingPlaneGeometry,
            alignment: .horizontal
        )
        if let result = planeResults.first {
            targetTransform = result.worldTransform
            // print("📍 Kitchen placed on floor at Y: \(result.worldTransform.columns.3.y)")
        }

        guard var finalTransform = targetTransform else {
            print("❌ No surface detected at tap location")
            return
        }

        // Orient kitchen so its local +Z points in the camera's forward direction (horizontal only)
        if let cameraTransform = arView.session.currentFrame?.camera.transform {
            let cameraForward  = -SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
            let camFwdFlat     = normalize(SIMD3<Float>(cameraForward.x, 0, cameraForward.z))
            let camRightFlat   = normalize(SIMD3<Float>(camFwdFlat.z, 0, -camFwdFlat.x))
            let up             = SIMD3<Float>(0, 1, 0)

            finalTransform.columns.0 = SIMD4<Float>(camRightFlat.x, camRightFlat.y, camRightFlat.z, 0)
            finalTransform.columns.1 = SIMD4<Float>(up.x,           up.y,           up.z,           0)
            finalTransform.columns.2 = SIMD4<Float>(camFwdFlat.x,   camFwdFlat.y,   camFwdFlat.z,   0)
        }

        // Load and place the kitchen
        guard let kitchenURL = Bundle.main.url(forResource: "kitchen", withExtension: "usdz") else {
            print("⚠️ kitchen.usdz not found")
            return
        }

        do {
            let kitchenModel = try ModelEntity.loadModel(contentsOf: kitchenURL)
            kitchenModel.generateCollisionShapes(recursive: true)
            // print("✅ Generated collision shapes for kitchen")

            // Kitchen model pivot is already at ground level - no offset needed
            // kitchenModel.position = [0, -0.05, 0]

            let anchor = AnchorEntity(world: finalTransform)
            anchor.addChild(kitchenModel)
            arView.scene.addAnchor(anchor)

            // Remove previous kitchen if exists
            if let oldAnchor = placedAssetAnchors["kitchen"] {
                arView.scene.removeAnchor(oldAnchor)
            }

            placedAssets["kitchen"]          = kitchenModel
            placedAssetTransforms["kitchen"] = finalTransform
            placedAssetAnchors["kitchen"]    = anchor

            // print("✅ Placed kitchen at Y level: \(finalTransform.columns.3.y)")

            // Prompt to select wall for kitchen
            waitingForKitchenWall = true
            state.hasKitchen      = true

            isArmed       = false
            selectedAsset = nil

        } catch {
            print("❌ Failed to load kitchen model: \(error)")
        }
    }

    private func handleKitchenWallSelection(at location: CGPoint) {
        // Raycast to find vertical planes (walls)
        let wallResults = arView.raycast(
            from: location,
            allowing: .existingPlaneGeometry,
            alignment: .vertical
        )

        guard let wallResult = wallResults.first,
              let kitchenAnchor = placedAssetAnchors["kitchen"],
              let kitchenModel  = placedAssets["kitchen"] else {
            print("No wall detected or kitchen not found")
            return
        }

        // Wall hit point (on the wall surface)
        let wallHitPoint = SIMD3<Float>(
            wallResult.worldTransform.columns.3.x,
            wallResult.worldTransform.columns.3.y,
            wallResult.worldTransform.columns.3.z
        )

        // Wall normal from the vertical plane transform (column 2), flattened to horizontal
        var wallNormal = normalize(SIMD3<Float>(
            wallResult.worldTransform.columns.2.x,
            0,
            wallResult.worldTransform.columns.2.z
        ))

        // Kitchen's current world position
        let currentKitchenTransform = kitchenAnchor.transformMatrix(relativeTo: nil)
        let kitchenPosition = SIMD3<Float>(
            currentKitchenTransform.columns.3.x,
            currentKitchenTransform.columns.3.y,
            currentKitchenTransform.columns.3.z
        )

        // Ensure wall normal points toward the kitchen (away from the wall surface)
        if dot(kitchenPosition - wallHitPoint, wallNormal) < 0 {
            wallNormal = -wallNormal
        }

        // print("🧱 Wall normal (toward kitchen): \(wallNormal)")

        // Orient kitchen perpendicular to wall:
        //   local +Z = -wallNormal  (back of kitchen faces into the wall)
        //   local +Y = world up
        //   local +X = cross(up, +Z)
        let kitchenZ = -wallNormal
        let up       = SIMD3<Float>(0, 1, 0)
        let kitchenX = normalize(cross(up, kitchenZ))

        var newTransformMatrix = currentKitchenTransform
        newTransformMatrix.columns.0 = SIMD4<Float>(kitchenX.x, kitchenX.y, kitchenX.z, 0)
        newTransformMatrix.columns.1 = SIMD4<Float>(up.x,       up.y,       up.z,       0)
        newTransformMatrix.columns.2 = SIMD4<Float>(kitchenZ.x, kitchenZ.y, kitchenZ.z, 0)

        // Snap origin flush to wall: project kitchen position onto the wall plane
        // along the wall normal. The model origin sits at the back face, so this
        // lands it right on the wall surface.
        let distToWall  = dot(kitchenPosition - wallHitPoint, wallNormal)
        let snappedPos  = kitchenPosition - distToWall * wallNormal
        newTransformMatrix.columns.3 = SIMD4<Float>(snappedPos.x, kitchenPosition.y, snappedPos.z, 1.0)

        // print("📍 Snapped kitchen to wall: distToWall=\(distToWall)m, pos=(\(snappedPos.x), \(kitchenPosition.y), \(snappedPos.z))")

        // Re-anchor kitchen
        arView.scene.removeAnchor(kitchenAnchor)

        let newAnchor = AnchorEntity(world: newTransformMatrix)
        newAnchor.addChild(kitchenModel)
        arView.scene.addAnchor(newAnchor)

        if !kitchenModel.components.has(CollisionComponent.self) {
            // print("⚠️ Collision lost during re-anchor, regenerating...")
            kitchenModel.generateCollisionShapes(recursive: true)
        }

        // Update stored references
        placedAssetAnchors["kitchen"]    = newAnchor
        placedAssetTransforms["kitchen"] = newTransformMatrix

        // Recalculate gun position relative to kitchen's new position
        let relativeOffset = SIMD3<Float>(0.5823, 0.8431, -2.5297)
        let gunTransform   = calculateGunTransform(kitchenTransform: newTransformMatrix, relativeOffset: relativeOffset)
        placedAssetTransforms["gun"] = gunTransform
        // print("✅ Recalculated gun transform after kitchen re-anchor")

        // Load and place gun model at calculated position
        if let gunURL = Bundle.main.url(forResource: "gun", withExtension: "usdz") {
            do {
                if let oldAnchor = placedAssetAnchors["gun"] {
                    arView.scene.removeAnchor(oldAnchor)
                }

                let gunModel = try ModelEntity.loadModel(contentsOf: gunURL)

                let gunBounds    = gunModel.visualBounds(relativeTo: nil)
                let currentWidth = max(gunBounds.extents.x, gunBounds.extents.z)
                if currentWidth > 0 {
                    let scaleFactor: Float = 0.2 / currentWidth
                    gunModel.scale *= SIMD3<Float>(repeating: scaleFactor)
                }

                let rotX = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
                let rotZ = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
                gunModel.orientation = rotZ * rotX

                let gunAnchor = AnchorEntity(world: gunTransform)
                gunAnchor.addChild(gunModel)
                arView.scene.addAnchor(gunAnchor)

                placedAssets["gun"]          = gunModel
                placedAssetAnchors["gun"]    = gunAnchor
            } catch {
                print("❌ Failed to load gun model: \(error)")
            }
        }

        // print("✅ Kitchen snapped perpendicular to wall")

        // Update UI state
        waitingForKitchenWall = false
    }

    // MARK: - Save

    @objc private func handleSaveNotification(_ notification: Notification) {
        guard let roomId = notification.userInfo?["roomId"] as? String else { return }

        // print("💾 Saving testing room '\(roomId)'...")
        // print("   Capturing ARWorldMap...")

        // Get current world map from AR session
        arView.session.getCurrentWorldMap { [weak self] worldMap, error in
            guard let self = self else { return }

            if let error = error {
                print("❌ Failed to get world map: \(error.localizedDescription)")

                DispatchQueue.main.async {
                    let errorMessage = """
                    ARKit couldn't capture enough of your environment yet.

                    Please:
                    • Move your device around slowly
                    • Scan walls, floors, and furniture
                    • Look for areas with good lighting
                    • Try again in a few seconds

                    Error: \(error.localizedDescription)
                    """

                    NotificationCenter.default.post(
                        name: .testingRoomSaveError,
                        object: nil,
                        userInfo: ["error": errorMessage]
                    )
                }
                return
            }

            guard let worldMap = worldMap else {
                print("❌ World map is nil")

                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .testingRoomSaveError,
                        object: nil,
                        userInfo: ["error": "World map is nil. Please scan more of your environment."]
                    )
                }
                return
            }

            // print("✅ World map captured successfully")
            // print("   Anchors: \(worldMap.anchors.count)")
            // print("   Assets: \(self.placedAssetTransforms.count)")

            // Save the room data with world map and asset transforms
            RoomLibrary.saveTestingRoom(
                roomId: roomId,
                worldMap: worldMap,
                assets: self.placedAssetTransforms
            )

            // Dismiss on success
            DispatchQueue.main.async {
                self.onExit?()
            }
        }
    }

    // MARK: - Load

    private func loadTestingRoom(_ roomId: String) {
        guard let roomData = RoomLibrary.loadTestingRoom(roomId: roomId) else { return }
        let assetTransforms = roomData.assets

        // CRITICAL: Load the world map to establish correct coordinate system
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        config.initialWorldMap = roomData.worldMap

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        }

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation) {
            config.frameSemantics.insert(.personSegmentation)
        }

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        // Store transforms for later placement (after relocalization)
        placedAssetTransforms = assetTransforms

        // Don't place assets immediately - wait for relocalization
        // Assets will be placed via session(_:didAdd:) when world map anchors are restored
        // or we can add a relocalization check similar to TestingARViewController

        guard let kitchenTransform = assetTransforms["kitchen"],
              let kitchenURL       = Bundle.main.url(forResource: "kitchen", withExtension: "usdz") else { return }

        do {
            let kitchenModel = try ModelEntity.loadModel(contentsOf: kitchenURL)
            kitchenModel.generateCollisionShapes(recursive: true)

            // Kitchen model pivot is already at ground level - no offset needed
            // kitchenModel.position = [0, -0.05, 0]

            let anchor = AnchorEntity(world: kitchenTransform)
            anchor.addChild(kitchenModel)
            arView.scene.addAnchor(anchor)

            placedAssets["kitchen"]          = kitchenModel
            placedAssetAnchors["kitchen"]    = anchor

            // Calculate or load gun position
            if assetTransforms["gun"] == nil {
                let relativeOffset = SIMD3<Float>(0.5823, 0.8431, -2.5297)
                placedAssetTransforms["gun"] = calculateGunTransform(kitchenTransform: kitchenTransform, relativeOffset: relativeOffset)
            } else {
                placedAssetTransforms["gun"] = assetTransforms["gun"]
            }

            // Load and place gun model
            if let gunTransform = placedAssetTransforms["gun"],
               let gunURL       = Bundle.main.url(forResource: "gun", withExtension: "usdz") {
                let gunModel = try ModelEntity.loadModel(contentsOf: gunURL)

                let bounds       = gunModel.visualBounds(relativeTo: nil)
                let currentWidth = max(bounds.extents.x, bounds.extents.z)
                if currentWidth > 0 {
                    gunModel.scale *= SIMD3<Float>(repeating: 0.2 / currentWidth)
                }

                let rotX = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
                let rotZ = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
                gunModel.orientation = rotZ * rotX

                let gunAnchor = AnchorEntity(world: gunTransform)
                gunAnchor.addChild(gunModel)
                arView.scene.addAnchor(gunAnchor)

                placedAssets["gun"]       = gunModel
                placedAssetAnchors["gun"] = gunAnchor
            }

            // print("✅ Loaded kitchen at saved position")
        } catch {
            print("❌ Failed to load kitchen model: \(error)")
        }

        state.hasKitchen = true
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

    private func showScanningAlert(message: String) {
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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let saveTestingRoom        = Notification.Name("saveTestingRoom")
    static let testingRoomSaveError   = Notification.Name("testingRoomSaveError")
}
