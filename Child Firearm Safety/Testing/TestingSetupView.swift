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

enum TestingRoomTemplate: String, CaseIterable {
    case kitchen
    case garage
    case bedroom

    var assetName: String { rawValue }
    var displayName: String { rawValue.capitalized }

    // Per-room correction multipliers to normalize USDZ export scale in AR.
    var scaleMultiplier: Float {
        switch self {
        case .kitchen, .bedroom:
            return 1.0
        case .garage:
            return 0.5
        }
    }

    static func scaleMultiplier(for assetName: String) -> Float {
        TestingRoomTemplate(rawValue: assetName)?.scaleMultiplier ?? 1.0
    }
}

enum TestingSetupMode { case create, load }

// MARK: - Shared UI State

final class TestingSetupState: ObservableObject {
    @Published var hasPlacedRoom = false
    @Published var canSaveComposite = false
    @Published var placeActionLabel = "Place Kitchen"
    @Published var startPositionCaptured = false
    @Published var setupInstructionBanner = "Tap Place Kitchen, then tap the floor, then tap the wall behind it"
    @Published var uiState = SetupUIState()

    /// Non-nil when a room has been floor+wall placed and is awaiting user confirmation before advancing
    @Published var awaitingConfirmationForStage: String? = nil

    // Actions wired by the VC at viewDidLoad
    var placeRoomAction:    (() -> Void)?
    var clearAction:        (() -> Void)?
    var confirmAssetAction: (() -> Void)?
}

// MARK: - Top-level View

struct TestingSetupView: View {
    let mode: TestingSetupMode
    let createRoomTemplate: TestingRoomTemplate

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

    init(mode: TestingSetupMode, createRoomTemplate: TestingRoomTemplate = .kitchen) {
        self.mode = mode
        self.createRoomTemplate = createRoomTemplate
    }

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
                createRoomTemplate: createRoomTemplate,
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
                    Text(setupState.setupInstructionBanner)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.top, 60)
                        .padding(.horizontal, 12)
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
        Group {
            if let stageName = setupState.awaitingConfirmationForStage {
                assetConfirmationButtons(for: stageName)
            } else {
                SetupControlButtons(
                    onClear: {
                        setupState.clearAction?()
                    },
                    onPlace: {
                        setupState.placeRoomAction?()
                    },
                    onSave: {
                        showSaveSheet = true
                    },
                    canSave: setupState.canSaveComposite,
                    placeLabel: setupState.placeActionLabel
                )
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: showControls)
    }

    private func assetConfirmationButtons(for stageName: String) -> some View {
        HStack(spacing: 12) {
            Button {
                setupState.clearAction?()
            } label: {
                Label("Clear \(stageName.capitalized)", systemImage: "trash")
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }

            Button {
                setupState.confirmAssetAction?()
            } label: {
                Label("Save \(stageName.capitalized)", systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.green.opacity(0.2))
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.bottom, 20)
    }

    // MARK: - Save Sheet

    private var saveSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Name this testing room").font(.headline)

                TextField("e.g. my-\(createRoomTemplate.assetName)", text: $roomId)
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
    let createRoomTemplate: TestingRoomTemplate
    let state:       TestingSetupState
    let onExit:      () -> Void
    let onSaveError: (String) -> Void

    func makeUIViewController(context: Context) -> TestingWallSelectorViewController {
        let vc = TestingWallSelectorViewController()
        vc.roomId      = roomId
        vc.createRoomTemplate = createRoomTemplate
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
    var createRoomTemplate: TestingRoomTemplate = .kitchen
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
    private var isArmed: Bool = false
    private var selectedAsset: String? = nil
    private var waitingForRoomWall: Bool = false
    private var roomAwaitingWallSelection: String?
    private var startCameraTransform: simd_float4x4?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        setupARView()
        setupNotifications()

        // Wire the SwiftUI toolbar buttons back into this VC
        state.placeRoomAction    = { [weak self] in self?.placeSelectedRoom() }
        state.clearAction        = { [weak self] in self?.clearCurrentOrAllAssets() }
        state.confirmAssetAction = { [weak self] in self?.confirmCurrentAsset() }

        if let roomId = roomId {
            loadTestingRoom(roomId)
        } else {
            refreshCompositeUIState()
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

    private var roomStageOrder: [TestingStage] {
        TestingStage.allCases
    }

    private func nextMissingStage() -> TestingStage? {
        roomStageOrder.first { placedAssetTransforms[$0.assetName] == nil }
    }

    private func setVisibleStageForCompositeSetup(_ stage: TestingStage?) {
        // In create mode, only show the room currently being placed/adjusted.
        guard roomId == nil else { return }

        for candidate in TestingStage.allCases {
            let roomKey = candidate.assetName
            let gunKey = candidate.gunAssetKey
            let shouldShow = (stage == candidate)

            placedAssetAnchors[roomKey]?.isEnabled = shouldShow
            placedAssetAnchors[gunKey]?.isEnabled = shouldShow
        }
    }

    private func refreshCompositeUIState() {
        let placedCount = roomStageOrder.filter { placedAssetTransforms[$0.assetName] != nil }.count
        let allRoomsPlaced = (placedCount == roomStageOrder.count)
        state.startPositionCaptured = (startCameraTransform != nil)
        state.canSaveComposite = allRoomsPlaced && state.startPositionCaptured
        state.hasPlacedRoom = state.canSaveComposite

        if waitingForRoomWall, let roomAwaitingWallSelection, let stage = TestingStage(rawValue: roomAwaitingWallSelection) {
            state.placeActionLabel = "Place \(stage.displayName)"
            state.setupInstructionBanner = "Tap the wall behind the \(stage.displayName.lowercased()) to lock the placement"
            return
        }

        if let nextStage = nextMissingStage() {
            state.placeActionLabel = "Place \(nextStage.displayName)"
            if let selectedAsset, isArmed, selectedAsset == nextStage.assetName {
                state.setupInstructionBanner = "Tap the floor to place the \(nextStage.displayName.lowercased()), then tap the wall behind it"
            } else if placedCount == 0 {
                state.setupInstructionBanner = "Tap Place Kitchen, then tap the floor, then tap the wall behind it"
            } else {
                state.setupInstructionBanner = "If the placement is good, tap Place \(nextStage.displayName)"
            }
        } else if startCameraTransform == nil {
            state.placeActionLabel = "Set Start Position"
            state.setupInstructionBanner = "If the bedroom placement is good, stand at the starting spot and tap Set Start Position"
        } else {
            state.placeActionLabel = "Re-set Start Position"
            state.setupInstructionBanner = "Start position saved. If everything looks correct, tap Save Room"
        }
    }

    private func placeSelectedRoom() {
        if let nextStage = nextMissingStage() {
            isArmed = true
            selectedAsset = nextStage.assetName
            setVisibleStageForCompositeSetup(nextStage)
            return
        }

        guard let cameraTransform = arView.session.currentFrame?.camera.transform else {
            showScanningAlert(message: "Move the device a little more, then try setting the start position again.")
            return
        }
        setVisibleStageForCompositeSetup(nil)
        startCameraTransform = cameraTransform

        // Raycast floor to place start marker at device feet
        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        let hits = arView.raycast(from: screenCenter, allowing: .estimatedPlane, alignment: .horizontal)
        if let hit = hits.first {
            placedAssetTransforms["startMarker"] = hit.worldTransform
            // Show a flat red visual in setup so the adult sees the marker
            let mesh = MeshResource.generatePlane(width: 0.6, depth: 0.6, cornerRadius: 0.3)
            var mat = SimpleMaterial()
            mat.color = .init(tint: UIColor.systemRed.withAlphaComponent(0.8))
            let entity = ModelEntity(mesh: mesh, materials: [mat])
            let anchor = AnchorEntity(world: hit.worldTransform)
            anchor.addChild(entity)
            arView.scene.addAnchor(anchor)
            placedAssetAnchors["startMarker"] = anchor
            print("📍 [TestingSetup] Start marker placed at device feet")
        }

        refreshCompositeUIState()
    }

    /// Clears only the asset currently awaiting confirmation; falls back to clearing everything.
    private func clearCurrentOrAllAssets() {
        if let stageName = state.awaitingConfirmationForStage,
           let stage = TestingStage(rawValue: stageName) {
            // Remove only this stage's room + gun
            let roomKey = stage.assetName
            let gunKey  = stage.gunAssetKey
            for key in [roomKey, gunKey] {
                if let anchor = placedAssetAnchors[key] {
                    arView.scene.removeAnchor(anchor)
                }
                placedAssets.removeValue(forKey: key)
                placedAssetTransforms.removeValue(forKey: key)
                placedAssetAnchors.removeValue(forKey: key)
            }
            state.awaitingConfirmationForStage = nil
            waitingForRoomWall = false
            roomAwaitingWallSelection = nil
            // Re-arm so the user can re-place this stage
            isArmed = true
            selectedAsset = roomKey
            setVisibleStageForCompositeSetup(stage)
            refreshCompositeUIState()
        } else {
            // No confirmation in progress — clear everything
            for (_, anchor) in placedAssetAnchors {
                arView.scene.removeAnchor(anchor)
            }
            placedAssets.removeAll()
            placedAssetTransforms.removeAll()
            placedAssetAnchors.removeAll()
            startCameraTransform = nil
            state.awaitingConfirmationForStage = nil
            state.hasPlacedRoom = false
            refreshCompositeUIState()
        }
    }

    /// Called when user taps "Save [Room]" in the confirmation UI — advances to the next stage.
    private func confirmCurrentAsset() {
        state.awaitingConfirmationForStage = nil
        roomAwaitingWallSelection = nil
        if let nextStage = nextMissingStage() {
            setVisibleStageForCompositeSetup(nextStage)
        }
        refreshCompositeUIState()
    }

    // MARK: - Tap Handling

    private func upsertGun(for stage: TestingStage, roomTransform: simd_float4x4, explicitTransform: simd_float4x4? = nil) {
        let gunKey = stage.gunAssetKey
        let gunTransform = explicitTransform ?? RoomLibrary.calculateGunTransform(roomTransform: roomTransform, relativeOffset: stage.gunRelativeOffset, yawOffset: stage.gunYawOffset)
        placedAssetTransforms[gunKey] = gunTransform

        if let oldAnchor = placedAssetAnchors[gunKey] {
            arView.scene.removeAnchor(oldAnchor)
        }

        guard let gunURL = Bundle.main.url(forResource: "gun", withExtension: "usdz") else { return }
        do {
            let gunModel = try ModelEntity.loadModel(contentsOf: gunURL)
            let bounds = gunModel.visualBounds(relativeTo: nil)
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

            placedAssets[gunKey] = gunModel
            placedAssetAnchors[gunKey] = gunAnchor
        } catch {
            print("❌ Failed to load gun model: \(error)")
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: arView)

        if waitingForRoomWall {
            handleRoomWallSelection(at: location)
            return
        }

        guard isArmed, let selectedAssetName = selectedAsset else { return }

        // Check world mapping status before allowing placement
        if let frame = arView.session.currentFrame {
            let status = frame.worldMappingStatus
            if status == .notAvailable || status == .limited {
                let message: String
                if status == .notAvailable {
                    message = "Cannot place \(selectedAssetName) yet.\n\nPlease move your device slowly around the area to scan surfaces and create spatial anchors."
                } else {
                    message = "Insufficient scanning detected.\n\nMove your device around to scan more of the floor, walls, and surrounding area before placing the \(selectedAssetName).\n\nMapping status: \(statusDescription(status))"
                }

                DispatchQueue.main.async { [weak self] in
                    self?.showScanningAlert(message: message)
                }
                return
            }
        }

        var targetTransform: simd_float4x4?

        // Room placement: only allow horizontal floor placement
        let planeResults = arView.raycast(
            from: location,
            allowing: .existingPlaneGeometry,
            alignment: .horizontal
        )
        if let result = planeResults.first {
            targetTransform = result.worldTransform
            // print("📍 Room placed on floor at Y: \(result.worldTransform.columns.3.y)")
        }

        guard var finalTransform = targetTransform else {
            print("❌ No surface detected at tap location")
            return
        }

        // Orient room so its local +Z points in the camera's forward direction (horizontal only)
        if let cameraTransform = arView.session.currentFrame?.camera.transform {
            let cameraForward  = -SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
            let camFwdFlat     = normalize(SIMD3<Float>(cameraForward.x, 0, cameraForward.z))
            let camRightFlat   = normalize(SIMD3<Float>(camFwdFlat.z, 0, -camFwdFlat.x))
            let up             = SIMD3<Float>(0, 1, 0)

            finalTransform.columns.0 = SIMD4<Float>(camRightFlat.x, camRightFlat.y, camRightFlat.z, 0)
            finalTransform.columns.1 = SIMD4<Float>(up.x,           up.y,           up.z,           0)
            finalTransform.columns.2 = SIMD4<Float>(camFwdFlat.x,   camFwdFlat.y,   camFwdFlat.z,   0)
        }

        // Load and place the selected room
        guard let roomURL = Bundle.main.url(forResource: selectedAssetName, withExtension: "usdz") else {
            print("⚠️ \(selectedAssetName).usdz not found")
            return
        }

        do {
            let roomModel = try ModelEntity.loadModel(contentsOf: roomURL)
            let roomScale = TestingRoomTemplate.scaleMultiplier(for: selectedAssetName)
            if roomScale != 1.0 {
                roomModel.scale *= SIMD3<Float>(repeating: roomScale)
            }
            roomModel.generateCollisionShapes(recursive: true)
            // print("✅ Generated collision shapes for room")

            // Room model pivot is expected at ground level
            // roomModel.position = [0, -0.05, 0]

            let anchor = AnchorEntity(world: finalTransform)
            anchor.addChild(roomModel)
            arView.scene.addAnchor(anchor)

            // Remove previous instance of this room if it exists
            if let oldAnchor = placedAssetAnchors[selectedAssetName] {
                arView.scene.removeAnchor(oldAnchor)
            }

            placedAssets[selectedAssetName] = roomModel
            placedAssetTransforms[selectedAssetName] = finalTransform
            placedAssetAnchors[selectedAssetName] = anchor

            // print("✅ Placed room at Y level: \(finalTransform.columns.3.y)")

            // Prompt to select wall behind the room
            waitingForRoomWall = true
            roomAwaitingWallSelection = selectedAssetName
            if let stage = TestingStage(rawValue: selectedAssetName) {
                setVisibleStageForCompositeSetup(stage)
            }
            refreshCompositeUIState()

            isArmed       = false
            selectedAsset = nil

        } catch {
            print("❌ Failed to load \(selectedAssetName) model: \(error)")
        }
    }

    private func handleRoomWallSelection(at location: CGPoint) {
        guard let roomAssetName = roomAwaitingWallSelection else {
            return
        }

        // Raycast to find vertical planes (walls)
        let wallResults = arView.raycast(
            from: location,
            allowing: .existingPlaneGeometry,
            alignment: .vertical
        )

        guard let wallResult = wallResults.first,
              let roomAnchor = placedAssetAnchors[roomAssetName],
              let roomModel = placedAssets[roomAssetName] else {
            print("No wall detected or placed room not found")
            return
        }

        // Wall hit point (on the wall surface)
        let wallHitPoint = SIMD3<Float>(
            wallResult.worldTransform.columns.3.x,
            wallResult.worldTransform.columns.3.y,
            wallResult.worldTransform.columns.3.z
        )

        // Wall normal from the vertical plane transform (column 1 / Y-axis), flattened to horizontal.
        // ARKit planes lie in their local X-Z plane, so column 1 (Y) is the surface normal.
        var wallNormal = normalize(SIMD3<Float>(
            wallResult.worldTransform.columns.1.x,
            0,
            wallResult.worldTransform.columns.1.z
        ))

        // Room's current world position
        let currentRoomTransform = roomAnchor.transformMatrix(relativeTo: nil)
        let roomPosition = SIMD3<Float>(
            currentRoomTransform.columns.3.x,
            currentRoomTransform.columns.3.y,
            currentRoomTransform.columns.3.z
        )

        // Ensure wall normal points toward the room (away from the wall surface)
        if dot(roomPosition - wallHitPoint, wallNormal) < 0 {
            wallNormal = -wallNormal
        }

        // print("🧱 Wall normal (toward room): \(wallNormal)")

        // Orient room perpendicular to wall:
        //   local +Z = -wallNormal  (back of room faces into the wall)
        //   local +Y = world up
        //   local +X = cross(up, +Z)
        let roomZ = -wallNormal
        let up    = SIMD3<Float>(0, 1, 0)
        let roomX = normalize(cross(up, roomZ))

        var newTransformMatrix = currentRoomTransform
        newTransformMatrix.columns.0 = SIMD4<Float>(roomX.x, roomX.y, roomX.z, 0)
        newTransformMatrix.columns.1 = SIMD4<Float>(up.x,       up.y,       up.z,       0)
        newTransformMatrix.columns.2 = SIMD4<Float>(roomZ.x, roomZ.y, roomZ.z, 0)

        // Snap origin flush to wall: project room position onto the wall plane
        // along the wall normal. The model origin sits at the back face, so this
        // lands it right on the wall surface.
        let distToWall = dot(roomPosition - wallHitPoint, wallNormal)
        let snappedPos = roomPosition - distToWall * wallNormal
        newTransformMatrix.columns.3 = SIMD4<Float>(snappedPos.x, roomPosition.y, snappedPos.z, 1.0)

        // print("📍 Snapped room to wall: distToWall=\(distToWall)m, pos=(\(snappedPos.x), \(roomPosition.y), \(snappedPos.z))")

        // Re-anchor room
        arView.scene.removeAnchor(roomAnchor)

        let newAnchor = AnchorEntity(world: newTransformMatrix)
        newAnchor.addChild(roomModel)
        arView.scene.addAnchor(newAnchor)

        if !roomModel.components.has(CollisionComponent.self) {
            // print("⚠️ Collision lost during re-anchor, regenerating...")
            roomModel.generateCollisionShapes(recursive: true)
        }

        // Update stored references
        placedAssetAnchors[roomAssetName] = newAnchor
        placedAssetTransforms[roomAssetName] = newTransformMatrix

        if let stage = TestingStage(rawValue: roomAssetName) {
            upsertGun(for: stage, roomTransform: newTransformMatrix)
        }

        // print("✅ Room snapped perpendicular to wall")

        // Enter confirmation state — show Clear/Save buttons before advancing
        waitingForRoomWall = false
        // roomAwaitingWallSelection kept so clearCurrentOrAllAssets knows which stage to clear
        state.awaitingConfirmationForStage = roomAssetName
        if let stage = TestingStage(rawValue: roomAssetName) {
            setVisibleStageForCompositeSetup(stage)
            state.setupInstructionBanner = "Does the \(stage.displayName.lowercased()) look good? Clear to redo or Save to continue."
        }
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
                assets: self.placedAssetTransforms,
                startCameraTransform: self.startCameraTransform
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
        startCameraTransform = roomData.startCameraTransform

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

        for stage in TestingStage.allCases {
            guard let roomTransform = assetTransforms[stage.assetName],
                  let roomURL = Bundle.main.url(forResource: stage.assetName, withExtension: "usdz") else { continue }
            do {
                let roomModel = try ModelEntity.loadModel(contentsOf: roomURL)
                let roomScale = TestingRoomTemplate.scaleMultiplier(for: stage.assetName)
                if roomScale != 1.0 {
                    roomModel.scale *= SIMD3<Float>(repeating: roomScale)
                }
                roomModel.generateCollisionShapes(recursive: true)
                let anchor = AnchorEntity(world: roomTransform)
                anchor.addChild(roomModel)
                arView.scene.addAnchor(anchor)
                placedAssets[stage.assetName] = roomModel
                placedAssetAnchors[stage.assetName] = anchor

                let savedGunTransform = assetTransforms[stage.gunAssetKey]
                upsertGun(for: stage, roomTransform: roomTransform, explicitTransform: savedGunTransform)
            } catch {
                print("❌ Failed to load room model \(stage.assetName): \(error)")
            }
        }

        refreshCompositeUIState()
        if roomId == nil {
            setVisibleStageForCompositeSetup(nextMissingStage())
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
