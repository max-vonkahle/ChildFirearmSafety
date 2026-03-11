//
//  TestingOrchestratorView.swift
//  Child Firearm Safety
//
//  Multi-room safety testing (kitchen -> garage -> bedroom)
//

import SwiftUI
import ARKit
import RealityKit

struct TestingOrchestratorView: View {
    enum Phase {
        case loadingAR
        case stageIntroPrompt
        case inStage
        case returnToStart
        case completed
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var coach = VoiceCoach(promptKey: "testingPrompt")
    @AppStorage("cardboardMode") private var cardboardMode = false

    @State private var showHeadsetInstruction = false
    @State private var showLoadingScreen = false
    @State private var showStartPrompt = false
    @State private var showCamera = false
    @State private var sceneReady = false
    @State private var selectedRoomId: String? = nil
    @State private var roomNames: [String] = RoomLibrary.savedTestingRooms()
    @State private var resetAttempts: Int = 0
    private let maxResetAttempts: Int = 3
    @State private var arEventObserver: NSObjectProtocol?
    @State private var testingStageObserver: NSObjectProtocol?
    @State private var lastReachGestureTime: Date?
    @State private var runawayPraiseTask: Task<Void, Never>? = nil
    @State private var modelEngagedSinceRunaway = false

    @State private var stageSequence: [TestingStage] = [.kitchen, .garage, .bedroom]
    @State private var currentStageIndex = 0
    @State private var phase: Phase = .loadingAR
    @State private var isWaitingForStageAdvance = false
    @State private var stagePromptSent = false

    @State private var startCameraTransform: simd_float4x4?
    @State private var alignmentStatus: StartPositionAlignmentStatus?
    @State private var isAlignmentTrackingEnabled = false
    @State private var startPoseMissingFallback = false

    private var currentStage: TestingStage { stageSequence[min(currentStageIndex, max(stageSequence.count - 1, 0))] }

    var body: some View {
        Group {
            if selectedRoomId == nil {
                RoomPickerView(
                    title: "Choose a Testing Room",
                    emptyMessage: "Create a testing room first using Testing Setup.",
                    rooms: roomNames,
                    onPick: { name in
                        selectedRoomId = name
                        resetTestingSessionState()
                    },
                    onDelete: { name in
                        RoomLibrary.deleteTestingRoom(name)
                        roomNames = RoomLibrary.savedTestingRooms()
                    }
                )
                .onAppear { roomNames = RoomLibrary.savedTestingRooms() }
            } else {
                testingScene
            }
        }
    }

    private var testingScene: some View {
        ZStack {
            if cardboardMode {
                TestingStereoARContainer(
                    roomId: selectedRoomId,
                    activeStage: currentStage,
                    alignmentTrackingEnabled: isAlignmentTrackingEnabled,
                    onAlignmentStatus: { status in alignmentStatus = status },
                    onLoadedStartTransform: { transform in
                        startCameraTransform = transform
                        startPoseMissingFallback = (transform == nil)
                    },
                    onSceneReady: {
                        sceneReady = true
                        phase = .stageIntroPrompt
                        withAnimation {
                            showLoadingScreen = false
                            showStartPrompt = true
                        }
                    }
                )
                .ignoresSafeArea()
                .scaleEffect(0.98)
                .opacity(showCamera ? 1 : 0)
                .onDisappear { coach.stopSession() }
            } else {
                TestingARView(
                    roomId: selectedRoomId,
                    activeStage: currentStage,
                    alignmentTrackingEnabled: isAlignmentTrackingEnabled,
                    onAlignmentStatus: { status in alignmentStatus = status },
                    onLoadedStartTransform: { transform in
                        startCameraTransform = transform
                        startPoseMissingFallback = (transform == nil)
                    },
                    onSceneReady: {
                        sceneReady = true
                        phase = .stageIntroPrompt
                        withAnimation {
                            showLoadingScreen = false
                            showStartPrompt = true
                        }
                    },
                    onExit: {
                        coach.stopSession()
                        dismiss()
                    }
                )
                .opacity(showCamera ? 1 : 0)
                .onDisappear { coach.stopSession() }
            }

            if !showCamera {
                Color.black.ignoresSafeArea()
            }

            if showHeadsetInstruction {
                HeadsetInstructionView {
                    withAnimation {
                        showHeadsetInstruction = false
                        showLoadingScreen = true
                    }
                }
            }

            if showLoadingScreen {
                LoadingScreenView(message: "Loading your testing environment...")
            }

            if showStartPrompt {
                StartTestingPromptView {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showStartPrompt = false
                        showCamera = true
                    }
                    coach.startSession()
                    phase = .inStage
                    sendStagePromptIfNeeded(force: true)
                }
            }

            if showCamera {
                VStack {
                    MicIndicatorView(coach: coach)
                    Spacer()
                }
            }

            if showCamera && phase == .returnToStart {
                returnToStartOverlay
            }

            if showCamera && phase == .completed {
                testingCompleteOverlay
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
        .onAppear {
            installObservers()
            showHeadsetInstruction = cardboardMode
            showLoadingScreen = !cardboardMode
        }
        .onDisappear { removeObservers() }
        .onChange(of: coach.state) { _, newState in
            if newState == .thinking {
                modelEngagedSinceRunaway = true
                runawayPraiseTask?.cancel()
                runawayPraiseTask = nil
            }
        }
        .onChange(of: phase) { _, newPhase in
            isAlignmentTrackingEnabled = (newPhase == .returnToStart) && !startPoseMissingFallback
            if newPhase == .inStage {
                sendStagePromptIfNeeded()
            }
        }
        .onChange(of: currentStageIndex) { _, _ in
            resetAttempts = 0
            stagePromptSent = false
            if phase == .inStage {
                sendStagePromptIfNeeded(force: true)
            }
        }
    }

    private var returnToStartOverlay: some View {
        VStack(spacing: 14) {
            Text("Return to Start Position")
                .font(.title2.bold())

            Text(startPoseMissingFallback
                 ? "This room setup does not include a saved start position. You can continue manually."
                 : (alignmentStatus?.guidanceText ?? "Move to the saved start position"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if let alignmentStatus, !startPoseMissingFallback {
                Text(String(format: "Distance: %.2fm  |  Turn error: %.0f°", alignmentStatus.horizontalDistanceMeters, alignmentStatus.yawDeltaDegrees))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button {
                guard canAdvanceFromStartOverlay else { return }
                advanceToNextStage()
            } label: {
                Text(currentStageIndex + 1 < stageSequence.count ? "Start \(stageSequence[currentStageIndex + 1].displayName)" : "Finish")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canAdvanceFromStartOverlay ? Color.blue : Color.gray)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!canAdvanceFromStartOverlay)
        }
        .padding()
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
    }

    private var testingCompleteOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("Testing Complete")
                .font(.largeTitle.bold())
            Text("All three safety testing scenarios are finished.")
                .foregroundStyle(.secondary)
            Button("Back to Room Picker") {
                coach.stopSession()
                selectedRoomId = nil
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 30)
    }

    private var canAdvanceFromStartOverlay: Bool {
        startPoseMissingFallback || (alignmentStatus?.isAligned == true)
    }

    private func resetTestingSessionState() {
        runawayPraiseTask?.cancel()
        runawayPraiseTask = nil
        modelEngagedSinceRunaway = false
        showHeadsetInstruction = false
        showLoadingScreen = false
        showStartPrompt = false
        showCamera = false
        sceneReady = false
        phase = .loadingAR
        currentStageIndex = 0
        resetAttempts = 0
        stagePromptSent = false
        isWaitingForStageAdvance = false
        startCameraTransform = nil
        alignmentStatus = nil
        isAlignmentTrackingEnabled = false
        startPoseMissingFallback = false
    }

    private func installObservers() {
        if arEventObserver == nil {
            arEventObserver = NotificationCenter.default.addObserver(
                forName: .arTestingEvent,
                object: nil,
                queue: .main
            ) { [self] note in
                guard let event = note.userInfo?[BusKey.arevent] as? AREvent else { return }
                switch event {
                case .reachGesture:
                    handleReachGesture()
                case .childRunsAway:
                    handleRunAway()
                default:
                    break
                }
            }
        }

        if testingStageObserver == nil {
            testingStageObserver = NotificationCenter.default.addObserver(
                forName: .testingStageComplete,
                object: nil,
                queue: .main
            ) { _ in
                handleStageCompleteSignal()
            }
        }
    }

    private func removeObservers() {
        if let observer = arEventObserver {
            NotificationCenter.default.removeObserver(observer)
            arEventObserver = nil
        }
        if let observer = testingStageObserver {
            NotificationCenter.default.removeObserver(observer)
            testingStageObserver = nil
        }
    }

    private func sendStagePromptIfNeeded(force: Bool = false) {
        guard showCamera, phase == .inStage else { return }
        if stagePromptSent && !force { return }
        stagePromptSent = true
        isWaitingForStageAdvance = true

        let stage = currentStage
        let runtimeText = """
        Current room: \(stage.displayName).
        \(stage.scenarioSetupText)

        Stay silent and observe. Do not say anything unless the child directly asks you a question or says something unsafe.
        When the room scenario is fully complete, output EXACTLY: [TEST_STAGE_COMPLETE]
        """
        coach.sendTestingStageInstruction(runtimeText)
    }

    private func handleStageCompleteSignal() {
        guard showCamera, phase == .inStage, isWaitingForStageAdvance else { return }
        isWaitingForStageAdvance = false
        runawayPraiseTask?.cancel()
        runawayPraiseTask = nil

        if currentStageIndex >= stageSequence.count - 1 {
            phase = .completed
            coach.stopSession()
            NotificationCenter.default.post(name: .testingSessionComplete, object: nil)
            return
        }

        phase = .returnToStart
    }

    private func advanceToNextStage() {
        guard currentStageIndex < stageSequence.count - 1 else {
            phase = .completed
            return
        }
        currentStageIndex += 1
        alignmentStatus = nil
        phase = .inStage
        NotificationCenter.default.post(name: .arCommand, object: nil, userInfo: [BusKey.arg: "setGunVisibility:true"])
    }

    private func handleRunAway() {
        guard phase == .inStage else { return }
        runawayPraiseTask?.cancel()
        modelEngagedSinceRunaway = false

        runawayPraiseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, phase == .inStage, !modelEngagedSinceRunaway else { return }
            let context = """
            The child has moved away from the gun in the \(currentStage.displayName.lowercased()) and has been silent for 15 seconds. \
            Praise them enthusiastically for moving away. Then gently ask if they know what the last important step is — \
            telling a trusted adult about what they found. Keep the tone warm and encouraging.
            """
            coach.injectContext(context)
        }
    }

    private func handleReachGesture() {
        guard phase == .inStage else { return }
        runawayPraiseTask?.cancel()
        runawayPraiseTask = nil

        let now = Date()
        if let lastTime = lastReachGestureTime,
           now.timeIntervalSince(lastTime) < 0.5 {
            return
        }
        lastReachGestureTime = now

        resetAttempts += 1

        NotificationCenter.default.post(
            name: .arCommand,
            object: nil,
            userInfo: [BusKey.arg: "setGunVisibility:false"]
        )

        let context = """
        The child reached for the gun during testing in the \(currentStage.displayName.lowercased()) scenario. Tell them:
        1. That was incorrect
        2. They should not touch the gun
        3. Step back and try again from the beginning of this room scenario
        Keep the tone calm and supportive.
        """
        coach.injectContext(context)

        if resetAttempts >= maxResetAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
                coach.stopSession()
                selectedRoomId = nil
            }
        }
    }
}

struct TestingARView: UIViewControllerRepresentable {
    let roomId: String?
    let activeStage: TestingStage
    let alignmentTrackingEnabled: Bool
    let onAlignmentStatus: (StartPositionAlignmentStatus?) -> Void
    let onLoadedStartTransform: (simd_float4x4?) -> Void
    let onSceneReady: () -> Void
    let onExit: () -> Void
    @AppStorage("cardboardMode") private var cardboardMode = false

    func makeUIViewController(context: Context) -> TestingARViewController {
        let vc = TestingARViewController()
        vc.roomId = roomId
        vc.activeTestingStage = activeStage
        vc.alignmentTrackingEnabled = alignmentTrackingEnabled
        vc.onAlignmentStatus = onAlignmentStatus
        vc.onLoadedStartTransform = onLoadedStartTransform
        vc.onSceneReady = onSceneReady
        vc.onExit = onExit
        vc.cardboardMode = cardboardMode
        return vc
    }

    func updateUIViewController(_ uiViewController: TestingARViewController, context: Context) {
        uiViewController.cardboardMode = cardboardMode
        uiViewController.onAlignmentStatus = onAlignmentStatus
        uiViewController.onLoadedStartTransform = onLoadedStartTransform
        uiViewController.alignmentTrackingEnabled = alignmentTrackingEnabled
        uiViewController.updateTestingStage(activeStage)
    }
}

struct TestingStereoARContainer: UIViewControllerRepresentable {
    let roomId: String?
    let activeStage: TestingStage
    let alignmentTrackingEnabled: Bool
    let onAlignmentStatus: (StartPositionAlignmentStatus?) -> Void
    let onLoadedStartTransform: (simd_float4x4?) -> Void
    let onSceneReady: () -> Void

    func makeUIViewController(context: Context) -> StereoARViewController {
        let vc = StereoARViewController(config: StereoConfig())
        vc.testingRoomId = roomId
        vc.testingActiveStage = activeStage
        vc.testingAlignmentTrackingEnabled = alignmentTrackingEnabled
        vc.onTestingAlignmentStatus = onAlignmentStatus
        vc.onTestingStartTransformLoaded = onLoadedStartTransform
        vc.onTestingSceneReady = onSceneReady
        return vc
    }

    func updateUIViewController(_ vc: StereoARViewController, context: Context) {
        vc.onTestingAlignmentStatus = onAlignmentStatus
        vc.onTestingStartTransformLoaded = onLoadedStartTransform
        vc.testingAlignmentTrackingEnabled = alignmentTrackingEnabled
        vc.updateTestingStage(activeStage)
    }
}

final class TestingARViewController: UIViewController {
    var roomId: String?
    var onSceneReady: (() -> Void)?
    var onExit: (() -> Void)?
    var cardboardMode: Bool = false
    var onAlignmentStatus: ((StartPositionAlignmentStatus?) -> Void)?
    var onLoadedStartTransform: ((simd_float4x4?) -> Void)?
    var activeTestingStage: TestingStage = .kitchen
    var alignmentTrackingEnabled: Bool = false

    private var arView: ARView!
    private var assetTransforms: [String: simd_float4x4] = [:]
    private var worldMapLoaded = false
    private var relocalizationTimer: Timer?
    private var placedStageAnchor: AnchorEntity?
    private var placedGunAnchor: AnchorEntity?
    private var startCameraTransform: simd_float4x4?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupARView()
        loadRoomData()

        relocalizationTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            guard let self = self, !self.worldMapLoaded else { return }
            self.worldMapLoaded = true
            self.placeAssetsForCurrentStage()
            self.onSceneReady?()
        }
    }

    private func setupARView() {
        arView = ARView(frame: view.bounds)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(arView)
        arView.session.delegate = self
    }

    private func loadRoomData() {
        guard let roomId else {
            startDefaultSession()
            onLoadedStartTransform?(nil)
            return
        }
        guard let roomData = RoomLibrary.loadTestingRoom(roomId: roomId) else {
            startDefaultSession()
            onLoadedStartTransform?(nil)
            return
        }

        assetTransforms = roomData.assets
        startCameraTransform = roomData.startCameraTransform
        onLoadedStartTransform?(startCameraTransform)

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

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
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
        if !assetTransforms.isEmpty {
            placeAssetsForCurrentStage()
        }
    }

    func updateTestingStage(_ stage: TestingStage) {
        guard activeTestingStage != stage else { return }
        activeTestingStage = stage
        if worldMapLoaded {
            placeAssetsForCurrentStage()
        }
    }

    private func placeAssetsForCurrentStage() {
        placedStageAnchor.map { arView.scene.removeAnchor($0) }
        placedGunAnchor.map { arView.scene.removeAnchor($0) }
        placedStageAnchor = nil
        placedGunAnchor = nil

        let stage = activeTestingStage
        guard let roomTransform = assetTransforms[stage.assetName] else {
            // Legacy fallback to kitchen-only saves
            if stage != .kitchen, let kitchen = assetTransforms[TestingStage.kitchen.assetName] {
                loadAssetPair(roomName: "kitchen", roomTransform: kitchen, stage: .kitchen)
            }
            return
        }

        loadAssetPair(roomName: stage.assetName, roomTransform: roomTransform, stage: stage)
    }

    private func loadAssetPair(roomName: String, roomTransform: simd_float4x4, stage: TestingStage) {
        placedStageAnchor = loadAsset(named: roomName, at: roomTransform)

        let gunTransform = assetTransforms[stage.gunAssetKey] ??
            RoomLibrary.calculateGunTransform(roomTransform: roomTransform, relativeOffset: stage.gunRelativeOffset, yawOffset: stage.gunYawOffset)
        placedGunAnchor = loadAsset(named: "gun", at: gunTransform, scale: 0.2)
    }

    @discardableResult
    private func loadAsset(named assetName: String, at transform: simd_float4x4, scale targetSize: Float? = nil) -> AnchorEntity? {
        guard let assetURL = Bundle.main.url(forResource: assetName, withExtension: "usdz") else {
            print("⚠️ \(assetName).usdz not found in bundle")
            return nil
        }

        do {
            let model = try ModelEntity.loadModel(contentsOf: assetURL)
            if let targetSize = targetSize {
                let bounds = model.visualBounds(relativeTo: nil)
                let currentWidth = max(bounds.extents.x, bounds.extents.z)
                if currentWidth > 0 {
                    model.scale *= SIMD3<Float>(repeating: targetSize / currentWidth)
                }
            } else {
                let roomScale = TestingRoomTemplate.scaleMultiplier(for: assetName)
                if roomScale != 1.0 {
                    model.scale *= SIMD3<Float>(repeating: roomScale)
                }
            }

            model.generateCollisionShapes(recursive: true)

            if assetName == "gun" {
                let rotX = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
                let rotZ = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
                model.orientation = rotZ * rotX
            }

            let anchor = AnchorEntity(world: transform)
            anchor.addChild(model)
            arView.scene.addAnchor(anchor)
            return anchor
        } catch {
            print("❌ Failed to load \(assetName): \(error)")
            return nil
        }
    }
}

extension TestingARViewController: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if alignmentTrackingEnabled, let startCameraTransform {
            let status = RoomLibrary.startAlignmentStatus(
                currentCameraTransform: frame.camera.transform,
                targetStartTransform: startCameraTransform
            )
            DispatchQueue.main.async { [weak self] in self?.onAlignmentStatus?(status) }
        } else {
            DispatchQueue.main.async { [weak self] in self?.onAlignmentStatus?(nil) }
        }

        guard !worldMapLoaded else { return }

        switch frame.worldMappingStatus {
        case .mapped, .extending:
            worldMapLoaded = true
            relocalizationTimer?.invalidate()
            DispatchQueue.main.async { [weak self] in
                self?.placeAssetsForCurrentStage()
                self?.onSceneReady?()
            }
        default:
            break
        }
    }
}

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

struct StartTestingPromptView: View {
    @AppStorage("cardboardMode") private var cardboardMode = false
    let onStart: () -> Void

    var body: some View {
        if cardboardMode {
            stereoPrompt
        } else {
            standardPrompt
        }
    }

    private var stereoPrompt: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    eyeContent.frame(width: geometry.size.width / 2, height: geometry.size.height)
                    eyeContent.frame(width: geometry.size.width / 2, height: geometry.size.height)
                }
            }
        }
        .onTapGesture { onStart() }
    }

    private var eyeContent: some View {
        VStack(spacing: 20) {
            Text("Tap anywhere to begin the testing")
                .font(.headline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 40))
                .foregroundColor(.white)
                .opacity(0.8)
        }
    }

    private var standardPrompt: some View {
        VStack(spacing: 24) {
            Image(systemName: "checklist.checked")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("Safety Testing")
                .font(.largeTitle)
                .bold()

            Text("You'll practice what you've learned\nin three virtual room scenarios")
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
