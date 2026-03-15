//
//  TestingOrchestratorView.swift
//  Child Firearm Safety
//
//  Multi-room safety testing (kitchen -> garage -> bedroom)
//

import SwiftUI
import ARKit
import RealityKit
import Vision
import UIKit

struct TestingOrchestratorView: View {
    enum Phase {
        case loadingAR
        case stageIntroPrompt
        case inStage
        case stageResetLoop
        case returnToStart
        case completed
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var coach = VoiceCoach(promptKey: "testingPrompt")
    @AppStorage("cardboardMode") private var cardboardMode = false
    @AppStorage("sessionRecordingEnabled") private var sessionRecordingEnabled = false

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
    @State private var vcIntentObserver: NSObjectProtocol?
    @State private var lastReachGestureTime: Date?
    @State private var runawayPraiseTask: Task<Void, Never>? = nil
    @State private var modelEngagedSinceRunaway = false
    @State private var didDetectRunAwayInCurrentStage = false

    @State private var stageSequence: [TestingStage] = [.kitchen, .garage, .bedroom]
    @State private var currentStageIndex = 0
    @State private var phase: Phase = .loadingAR
    @State private var isWaitingForStageAdvance = false
    @State private var stagePromptSent = false

    @State private var startCameraTransform: simd_float4x4?
    @State private var alignmentStatus: StartPositionAlignmentStatus?
    @State private var loadingMappingStatus = "Waiting for relocalization"
    @State private var isAlignmentTrackingEnabled = false
    @State private var startPoseMissingFallback = false
    @State private var hasReachedStartMarker = false
    @State private var hasReachedResetMarker = false
    @State private var isSessionRecordingActive = false

    private var currentStage: TestingStage { stageSequence[min(currentStageIndex, max(stageSequence.count - 1, 0))] }
    private var loadingDebugLines: [String] {
        // Hidden for now, but kept here so the start-alignment panel can be restored easily later.
//        guard showLoadingScreen else { return [] }
//        guard let alignmentStatus else { return ["Waiting for saved start position data"] }
//        return [
//            String(format: "Distance from saved start: %.2fm", alignmentStatus.horizontalDistanceMeters),
//            String(format: "Facing error: %.0f°", alignmentStatus.yawDeltaDegrees),
//            alignmentStatus.guidanceText
//        ]
        return []
    }

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
                    shouldRecordSession: isSessionRecordingActive,
                    alignmentTrackingEnabled: isAlignmentTrackingEnabled,
                    onAlignmentStatus: { status in alignmentStatus = status },
                    onWorldMappingStatus: { status in loadingMappingStatus = status },
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
                .onDisappear {
                    isSessionRecordingActive = false
                    exitTestingSession()
                }
            } else {
                TestingARView(
                    roomId: selectedRoomId,
                    activeStage: currentStage,
                    alignmentTrackingEnabled: isAlignmentTrackingEnabled,
                    onAlignmentStatus: { status in alignmentStatus = status },
                    onWorldMappingStatus: { status in loadingMappingStatus = status },
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
                        exitTestingSession()
                        dismiss()
                    }
                )
                .opacity(showCamera ? 1 : 0)
                .onDisappear {
                    isSessionRecordingActive = false
                    exitTestingSession()
                }
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
                LoadingScreenView(
                    message: "Loading your testing environment...",
                    onExit: {
                        exitTestingSession()
                    }
                )
            }

            if showStartPrompt {
                StartTestingPromptView {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showStartPrompt = false
                        showCamera = true
                    }
                    isSessionRecordingActive = sessionRecordingEnabled && cardboardMode
                    coach.startSession()
                    phase = .inStage
                    if sessionRecordingEnabled && !cardboardMode {
                        SessionScreenRecorder.shared.startIfNeeded()
                    }
                    sendStagePromptIfNeeded(force: true)
                }
            }

            if showCamera {
                VStack {
                    MicIndicatorView(coach: coach)
                    Spacer()
                }
            }

            if showCamera && phase == .completed {
                testingCompleteOverlay
            }
        }
        .overlay(alignment: .topTrailing) {
            if showCamera {
                Button {
                    exitTestingSession()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.12), in: Circle())
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
        .onDisappear {
            exitTestingSession()
            removeObservers()
        }
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
        Group {
            if cardboardMode {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        returnToStartCard
                            .frame(width: geometry.size.width / 2)
                        returnToStartCard
                            .frame(width: geometry.size.width / 2)
                    }
                }
            } else {
                returnToStartCard
            }
        }
    }

    private var returnToStartCard: some View {
        VStack(spacing: 14) {
            Text("Walk to the Red Circle")
                .font(.title2.bold())

            Text(returnToStartMessage)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if hasReachedStartMarker {
                Button {
                    attemptAdvanceFromStartOverlay()
                } label: {
                    Text("Tap to Move On")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(canAdvanceFromStartOverlay ? Color.blue : Color.gray)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!canAdvanceFromStartOverlay)
            } else if startPoseMissingFallback {
                Button {
                    attemptAdvanceFromStartOverlay()
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
        }
        .padding()
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var testingResetOverlay: some View {
        Group {
            if cardboardMode {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        testingResetCard
                            .frame(width: geometry.size.width / 2)
                        testingResetCard
                            .frame(width: geometry.size.width / 2)
                    }
                }
            } else {
                testingResetCard
            }
        }
    }

    private var testingResetCard: some View {
        VStack(spacing: 12) {
            Text("Reset to Try Again")
                .font(.title3.bold())

            Text(hasReachedResetMarker
                 ? "You are on the red circle. Tap anywhere on the screen to reset and try the room again."
                 : "Repeat the four safety steps, then walk to the red circle on the floor.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var returnToStartMessage: String {
        if startPoseMissingFallback {
            return hasReachedStartMarker
                ? "You are back at the saved start spot. Tap anywhere on the screen to move on."
                : "Walk back to your starting spot. Once you are there, tap anywhere on the screen to continue."
        }
        if !hasReachedStartMarker {
            return "Walk to the red circle on the floor. Once you are standing on it and facing the next room, tap anywhere on the screen to move on."
        }
        return canAdvanceFromStartOverlay
            ? "Great. You are back at the start and facing the room correctly. Tap anywhere on the screen to move on."
            : ((alignmentStatus?.guidanceText ?? "Turn to face the room before moving on.") + " Then tap anywhere on the screen to continue.")
    }

    private var testingCompleteOverlay: some View {
        ZStack {
            Color.black.opacity(0.85)
                .edgesIgnoringSafeArea(.all)

            if cardboardMode {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        testingCompleteContent
                            .frame(width: geometry.size.width / 2, height: geometry.size.height)
                        testingCompleteContent
                            .frame(width: geometry.size.width / 2, height: geometry.size.height)
                    }
                }
            } else {
                testingCompleteContent
            }
        }
        .onTapGesture {
            exitTestingSession()
        }
    }

    private var testingCompleteContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50))
                .foregroundColor(.green)

            Text("Great Job!")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text("Testing Complete")
                .font(.title3)
                .foregroundColor(.white.opacity(0.9))

            VStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.8))

                Text("Please take off the headset\nand give it to your instructor")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 12)
        }
        .padding(24)
    }

    private var canAdvanceFromStartOverlay: Bool {
        startPoseMissingFallback || (alignmentStatus?.isAligned == true)
    }

    private func resetTestingSessionState() {
        stopRecordingIfNeeded()
        runawayPraiseTask?.cancel()
        runawayPraiseTask = nil
        modelEngagedSinceRunaway = false
        didDetectRunAwayInCurrentStage = false
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
        loadingMappingStatus = "Waiting for relocalization"
        isAlignmentTrackingEnabled = false
        startPoseMissingFallback = false
        hasReachedStartMarker = false
        hasReachedResetMarker = false
    }

    private func exitTestingSession() {
        runawayPraiseTask?.cancel()
        runawayPraiseTask = nil
        coach.stopSession()
        resetTestingSessionState()
        selectedRoomId = nil
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
                case .childAtStartMarker:
                    handleChildAtStartMarker()
                case .userTappedToReset:
                    handleUserTappedToReset()
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

        if vcIntentObserver == nil {
            vcIntentObserver = NotificationCenter.default.addObserver(
                forName: .vcIntent,
                object: nil,
                queue: .main
            ) { [self] note in
                guard let intent = note.userInfo?[BusKey.vcintent] as? VCIntent else { return }
                handleVCIntent(intent)
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
        if let observer = vcIntentObserver {
            NotificationCenter.default.removeObserver(observer)
            vcIntentObserver = nil
        }
    }

    private func sendStagePromptIfNeeded(force: Bool = false) {
        guard showCamera, phase == .inStage else { return }
        if stagePromptSent && !force { return }
        stagePromptSent = true
        isWaitingForStageAdvance = true

        let stage = currentStage
        let isLastStage = currentStageIndex >= stageSequence.count - 1
        let runtimeText = """
        Current room: \(stage.displayName) (room \(currentStageIndex + 1) of \(stageSequence.count)\(isLastStage ? " — this is the LAST room" : "")).
        Scenario setup: \(stage.scenarioSetupText)
        Room intro to speak now: \(stage.startPromptText)

        Your very first response for this room must be the room intro once, naturally, in character.
        Use it to introduce the scene and cue the child into what they should be doing in this room.
        Do not explain your instructions, and do not say that you are going to stay silent.
        After the room intro, stay silent and observe unless the child directly asks you a question or says something unsafe.
        When the room scenario is fully complete, call signal_phase_complete(phase: "test_stage_complete").
        """
        coach.sendTestingStageInstruction(runtimeText)
    }

    private func handleStageCompleteSignal() {
        guard showCamera, phase == .inStage, isWaitingForStageAdvance else { return }
        isWaitingForStageAdvance = false
        runawayPraiseTask?.cancel()
        runawayPraiseTask = nil
        didDetectRunAwayInCurrentStage = false

        if currentStageIndex >= stageSequence.count - 1 {
            phase = .completed
            stopRecordingIfNeeded()
            // Don't stopSession() here — let the LLM finish speaking its praise before going idle.
            // onPlaybackComplete sees testingStageCompletionSignaled=true and cleans up automatically.
            NotificationCenter.default.post(name: .testingSessionComplete, object: nil)
            return
        }

        phase = .returnToStart
        hasReachedStartMarker = false
        hasReachedResetMarker = false

        // Show the red circle floor marker and tell the child to walk to it
        NotificationCenter.default.post(name: .arCommand, object: nil, userInfo: [BusKey.arg: "showStartMarker"])
        let nextStageName = stageSequence[currentStageIndex + 1].displayName
        coach.injectContext("Great job! Now walk to the red circle on the floor, face the next room, and tap anywhere on the screen to move on. The \(nextStageName) will start after that.")
    }

    private func handleChildAtStartMarker() {
        switch phase {
        case .returnToStart:
            print("📍 [Testing] Child reached start marker — waiting for tap to advance")
            hasReachedStartMarker = true
        case .stageResetLoop:
            print("📍 [Testing] Child reached reset marker — waiting for tap to reset stage")
            hasReachedResetMarker = true
        default:
            break
        }
    }

    private func handleUserTappedToReset() {
        switch phase {
        case .stageResetLoop:
            print("👆 [Testing] Reset tap received — restoring gun and prompting child to act it out again")
            hasReachedResetMarker = false
            didDetectRunAwayInCurrentStage = false
            phase = .inStage
            NotificationCenter.default.post(name: .arCommand, object: nil, userInfo: [BusKey.arg: "setGunVisibility:true"])
            coach.sendTestingPostResetActOut(stageName: currentStage.displayName)
        case .returnToStart:
            print("👆 [Testing] Start-marker tap received — advancing to next stage")
            attemptAdvanceFromStartOverlay()
        default:
            return
        }
    }

    private func advanceToNextStage() {
        guard currentStageIndex < stageSequence.count - 1 else {
            phase = .completed
            return
        }
        NotificationCenter.default.post(name: .arCommand, object: nil, userInfo: [BusKey.arg: "hideStartMarker"])
        hasReachedStartMarker = false
        currentStageIndex += 1
        alignmentStatus = nil
        didDetectRunAwayInCurrentStage = false
        phase = .inStage
        print("✅ [Testing] Advanced to stage \(currentStageIndex): \(currentStage.displayName)")
        NotificationCenter.default.post(name: .arCommand, object: nil, userInfo: [BusKey.arg: "setGunVisibility:true"])
        sendStagePromptIfNeeded(force: true)
    }

    private func attemptAdvanceFromStartOverlay() {
        guard phase == .returnToStart else {
            print("⚠️ [Testing] attemptAdvance blocked — phase is \(phase), not returnToStart")
            return
        }
        advanceToNextStage()
    }

    private func handleRunAway() {
        guard phase == .inStage else { return }
        print("🏃 [Testing] childRunsAway received in stage \(currentStage.displayName)")
        runawayPraiseTask?.cancel()
        modelEngagedSinceRunaway = false
        didDetectRunAwayInCurrentStage = true

        runawayPraiseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, phase == .inStage, !modelEngagedSinceRunaway else { return }
            print("🗣️ [Testing] Run-away follow-up fired after 8s silence in \(currentStage.displayName)")
            let context = """
            The child has moved away from the gun in the \(currentStage.displayName.lowercased()) and has been silent for 8 seconds. \
            Praise them enthusiastically for moving away. Then gently ask if they know what the last important step is — \
            telling a trusted adult about what they found. Keep the tone warm and encouraging.
            """
            coach.sendRunAwayFollowUp(context)
        }
    }

    private func handleReachGesture() {
        guard phase == .inStage else { return }
        runawayPraiseTask?.cancel()
        runawayPraiseTask = nil
        didDetectRunAwayInCurrentStage = false

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
        NotificationCenter.default.post(
            name: .arCommand,
            object: nil,
            userInfo: [BusKey.arg: "disableTapDuringSpeech"]
        )
        NotificationCenter.default.post(
            name: .arCommand,
            object: nil,
            userInfo: [BusKey.arg: "showStartMarker"]
        )
        phase = .stageResetLoop
        hasReachedResetMarker = false
        coach.sendTestingResetInstruction(stageName: currentStage.displayName)

        if resetAttempts >= maxResetAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
                stopRecordingIfNeeded()
                coach.stopSession()
                selectedRoomId = nil
            }
        }
    }

    private func stopRecordingIfNeeded() {
        isSessionRecordingActive = false
        if sessionRecordingEnabled && !cardboardMode {
            SessionScreenRecorder.shared.stopIfNeeded()
        }
    }

    private func handleVCIntent(_ intent: VCIntent) {
        guard phase == .inStage else { return }

        switch intent {
        case .calledAdult(let text, _):
            guard didDetectRunAwayInCurrentStage else { return }
            print("📢 [Testing] calledAdult received after run-away in \(currentStage.displayName): \(text)")
            modelEngagedSinceRunaway = true
            runawayPraiseTask?.cancel()
            runawayPraiseTask = nil
            didDetectRunAwayInCurrentStage = false
            coach.sendTestingCalledAdultAfterRunAway(stageName: currentStage.displayName, text: text, isLastStage: currentStageIndex >= stageSequence.count - 1)

        default:
            break
        }
    }
}

struct TestingARView: UIViewControllerRepresentable {
    let roomId: String?
    let activeStage: TestingStage
    let alignmentTrackingEnabled: Bool
    let onAlignmentStatus: (StartPositionAlignmentStatus?) -> Void
    let onWorldMappingStatus: (String) -> Void
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
        vc.onWorldMappingStatus = onWorldMappingStatus
        vc.onLoadedStartTransform = onLoadedStartTransform
        vc.onSceneReady = onSceneReady
        vc.onExit = onExit
        vc.cardboardMode = cardboardMode
        return vc
    }

    func updateUIViewController(_ uiViewController: TestingARViewController, context: Context) {
        uiViewController.cardboardMode = cardboardMode
        uiViewController.onAlignmentStatus = onAlignmentStatus
        uiViewController.onWorldMappingStatus = onWorldMappingStatus
        uiViewController.onLoadedStartTransform = onLoadedStartTransform
        uiViewController.alignmentTrackingEnabled = alignmentTrackingEnabled
        uiViewController.updateTestingStage(activeStage)
    }
}

struct TestingStereoARContainer: UIViewControllerRepresentable {
    let roomId: String?
    let activeStage: TestingStage
    let shouldRecordSession: Bool
    let alignmentTrackingEnabled: Bool
    let onAlignmentStatus: (StartPositionAlignmentStatus?) -> Void
    let onWorldMappingStatus: (String) -> Void
    let onLoadedStartTransform: (simd_float4x4?) -> Void
    let onSceneReady: () -> Void

    func makeUIViewController(context: Context) -> StereoARViewController {
        let vc = StereoARViewController(config: StereoConfig())
        vc.testingRoomId = roomId
        vc.testingActiveStage = activeStage
        vc.testingAlignmentTrackingEnabled = alignmentTrackingEnabled
        vc.onTestingAlignmentStatus = onAlignmentStatus
        vc.onTestingWorldMappingStatus = onWorldMappingStatus
        vc.onTestingStartTransformLoaded = onLoadedStartTransform
        vc.onTestingSceneReady = onSceneReady
        vc.shouldRecordSession = shouldRecordSession
        return vc
    }

    func updateUIViewController(_ vc: StereoARViewController, context: Context) {
        vc.onTestingAlignmentStatus = onAlignmentStatus
        vc.onTestingWorldMappingStatus = onWorldMappingStatus
        vc.onTestingStartTransformLoaded = onLoadedStartTransform
        vc.testingAlignmentTrackingEnabled = alignmentTrackingEnabled
        vc.shouldRecordSession = shouldRecordSession
        vc.updateTestingStage(activeStage)
    }
}

final class TestingARViewController: UIViewController {
    var roomId: String?
    var onSceneReady: (() -> Void)?
    var onExit: (() -> Void)?
    var cardboardMode: Bool = false
    var onAlignmentStatus: ((StartPositionAlignmentStatus?) -> Void)?
    var onWorldMappingStatus: ((String) -> Void)?
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
    private var startMarkerAnchor: AnchorEntity?
    private var startMarkerWorldPos: SIMD3<Float>?
    private var isWaitingForStartMarker: Bool = false
    private var isWaitingForResetSpeech: Bool = false
    private var isResetPending: Bool = false
    private var isStageAdvancePending: Bool = false
    private let markerReachDistance: Float = 0.5
    private var tapGesture: UITapGestureRecognizer?
    private let handRequest = VNDetectHumanHandPoseRequest()
    private let handRequestHandler = VNSequenceRequestHandler()
    private let visionQueue = DispatchQueue(label: "com.childgunsafety.testing.vision", qos: .userInitiated)
    private var cachedHandObservations: [VNHumanHandPoseObservation] = []
    private let observationsLock = NSLock()
    private var isVisionProcessing = false
    private var lastDecisionAt: CFTimeInterval = 0
    private let decisionInterval: CFTimeInterval = 0.15
    private var currentFrameNumber: Int = 0
    private var lastReachGestureFrame: Int = 0
    private var overlapReachStreak: Int = 0
    private var lastReportedWorldMappingStatus: String?
    private var lastReportedAlignmentStatus: StartPositionAlignmentStatus?
    private var wasNear: Bool = false
    private var lastNearDistance: Float = 0
    private var isRetreating: Bool = false
    private var retreatStartDistance: Float = 0
    private var retreatStartTime: CFTimeInterval = 0
    private var isAwaitingSettlement: Bool = false
    private var settlePeakDistance: Float = 0
    private var lastSignificantMoveTime: CFTimeInterval = 0
    private let retreatStartThreshold: Float = 0.15
    private let runAwayThreshold: Float = 5.0
    private let settleThreshold: Float = 0.15
    private let settleTime: CFTimeInterval = 1.5
    private let pixelPadding: CGFloat = 24
    private let depthMargin: Float = 0.07
    private let maxReachDistance: Float = 0.25

    override func viewDidLoad() {
        super.viewDidLoad()
        setupARView()
        loadRoomData()

        NotificationCenter.default.addObserver(forName: .arCommand, object: nil, queue: .main) { [weak self] note in
            guard let self, let cmd = note.userInfo?[BusKey.arg] as? String else { return }
            if cmd == "setGunVisibility:false" {
                self.setGunVisible(false)
                self.isResetPending = true
            } else if cmd == "setGunVisibility:true" {
                self.setGunVisible(true)
                self.isResetPending = false
                self.isWaitingForResetSpeech = false
            } else if cmd == "disableTapDuringSpeech" {
                self.isWaitingForResetSpeech = true
            } else if cmd == "enableTapAfterSpeech" {
                self.isWaitingForResetSpeech = false
            } else if cmd == "showStartMarker" {
                self.setStartMarkerVisible(true)
                self.isWaitingForStartMarker = true
                self.isStageAdvancePending = !self.isResetPending
            } else if cmd == "hideStartMarker" {
                self.setStartMarkerVisible(false)
                self.isWaitingForStartMarker = false
                self.isStageAdvancePending = false
            }
        }
    }

    private func setupARView() {
        arView = ARView(frame: view.bounds)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(arView)
        arView.session.delegate = self
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)
        self.tapGesture = tapGesture
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
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation) {
            config.frameSemantics.insert(.personSegmentation)
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
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation) {
            config.frameSemantics.insert(.personSegmentation)
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

    private func placeStartMarkerIfAvailable() {
        guard startMarkerAnchor == nil,
              let transform = assetTransforms["startMarker"] else { return }
        let mesh = MeshResource.generatePlane(width: 0.6, depth: 0.6, cornerRadius: 0.3)
        var mat = SimpleMaterial()
        mat.color = .init(tint: UIColor.systemRed.withAlphaComponent(0.85))
        let entity = ModelEntity(mesh: mesh, materials: [mat])
        entity.isEnabled = false  // Hidden by default
        let anchor = AnchorEntity(world: transform)
        anchor.addChild(entity)
        arView.scene.addAnchor(anchor)
        startMarkerAnchor = anchor
        let col = transform.columns.3
        startMarkerWorldPos = SIMD3<Float>(col.x, col.y, col.z)
        print("📍 [TestingAR] Start marker loaded at saved position")
    }

    private func setStartMarkerVisible(_ visible: Bool) {
        startMarkerAnchor?.children.forEach { $0.isEnabled = visible }
    }

    private func setGunVisible(_ visible: Bool) {
        placedGunAnchor?.isEnabled = visible
        if visible {
            wasNear = false
            lastNearDistance = 0
            isRetreating = false
            isAwaitingSettlement = false
            lastReachGestureFrame = 0
            overlapReachStreak = 0
        }
    }

    @objc private func handleTap(_ sender: UITapGestureRecognizer) {
        guard isResetPending || isStageAdvancePending else { return }

        if isWaitingForResetSpeech {
            print("⏭️ [TestingAR] Tap ignored - waiting for model to finish speaking")
            return
        }

        if isWaitingForStartMarker {
            if let frame = arView.session.currentFrame,
               let dist = startMarkerDistanceFromCamera(frame: frame) {
                print("⏭️ [TestingAR] Tap ignored - \(String(format: "%.2f", dist))m from marker (need ≤\(markerReachDistance)m)")
            } else {
                print("⏭️ [TestingAR] Tap ignored - child hasn't reached the start marker yet (position unavailable)")
            }
            return
        }

        print("✅ [TestingAR] User tapped on start marker flow - posting userTappedToReset event")
        setStartMarkerVisible(false)
        isStageAdvancePending = false
        NotificationCenter.default.post(
            name: .arTestingEvent,
            object: nil,
            userInfo: [BusKey.arevent: AREvent.userTappedToReset]
        )
    }

    private func startMarkerDistanceFromCamera(frame: ARFrame) -> Float? {
        guard let markerPos = startMarkerWorldPos else { return nil }
        let cam = frame.camera.transform.columns.3
        let dx = cam.x - markerPos.x
        let dz = cam.z - markerPos.z
        return sqrtf(dx * dx + dz * dz)
    }

    private func gunScreenRect() -> CGRect? {
        guard let gunAnchor = placedGunAnchor else { return nil }
        let bounds = gunAnchor.visualBounds(relativeTo: nil)
        let center = bounds.center
        let extents = bounds.extents
        let corners: [SIMD3<Float>] = [
            center + SIMD3(-extents.x / 2, -extents.y / 2, -extents.z / 2),
            center + SIMD3(-extents.x / 2, -extents.y / 2,  extents.z / 2),
            center + SIMD3(-extents.x / 2,  extents.y / 2, -extents.z / 2),
            center + SIMD3(-extents.x / 2,  extents.y / 2,  extents.z / 2),
            center + SIMD3( extents.x / 2, -extents.y / 2, -extents.z / 2),
            center + SIMD3( extents.x / 2, -extents.y / 2,  extents.z / 2),
            center + SIMD3( extents.x / 2,  extents.y / 2, -extents.z / 2),
            center + SIMD3( extents.x / 2,  extents.y / 2,  extents.z / 2)
        ]

        var pts: [CGPoint] = []
        for local in corners {
            let world = gunAnchor.convert(position: local, to: nil)
            if let p = arView.project(world) {
                pts.append(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            }
        }
        guard !pts.isEmpty else { return nil }
        let xs = pts.map(\.x)
        let ys = pts.map(\.y)
        return CGRect(
            x: xs.min()! - pixelPadding,
            y: ys.min()! - pixelPadding,
            width: (xs.max()! - xs.min()!) + 2 * pixelPadding,
            height: (ys.max()! - ys.min()!) + 2 * pixelPadding
        )
    }

    private func visionNormToScreen(_ loc: CGPoint) -> CGPoint {
        CGPoint(
            x: loc.x * arView.bounds.width,
            y: (1 - loc.y) * arView.bounds.height
        )
    }

    private func sampleDepthAtScreen(_ depthBuf: CVPixelBuffer, screenPoint: CGPoint) -> Float? {
        CVPixelBufferLockBaseAddress(depthBuf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuf, .readOnly) }
        let dmW = CVPixelBufferGetWidth(depthBuf)
        let dmH = CVPixelBufferGetHeight(depthBuf)
        let u = Int(round(screenPoint.x / arView.bounds.width * CGFloat(dmW)))
        let v = Int(round(screenPoint.y / arView.bounds.height * CGFloat(dmH)))

        let searchRadius = 3
        let rowStride = CVPixelBufferGetBytesPerRow(depthBuf) / MemoryLayout<Float32>.size
        let base = CVPixelBufferGetBaseAddress(depthBuf)!.assumingMemoryBound(to: Float32.self)
        var bestDepth: Float?

        for dv in -searchRadius...searchRadius {
            for du in -searchRadius...searchRadius {
                let sU = u + du, sV = v + dv
                guard sU >= 0, sU < dmW, sV >= 0, sV < dmH else { continue }
                let z = base[sV * rowStride + sU]
                guard z.isFinite, z > 0 else { continue }
                if let current = bestDepth {
                    if z < current { bestDepth = z }
                } else {
                    bestDepth = z
                }
            }
        }
        return bestDepth
    }

    private func gunDistanceFromCamera(frame: ARFrame) -> Float? {
        guard let gunAnchor = placedGunAnchor else { return nil }
        let gunPos = gunAnchor.position(relativeTo: nil)
        let camInv = frame.camera.transform.inverse
        let world = SIMD4<Float>(gunPos.x, gunPos.y, gunPos.z, 1)
        let rel = camInv * world
        let depth = -rel.z
        return depth.isFinite && depth > 0 ? depth : nil
    }

    private func triggerReachGesture(reason: String) {
        guard currentFrameNumber != lastReachGestureFrame else { return }
        lastReachGestureFrame = currentFrameNumber
        overlapReachStreak = 0

        print("🚨 [TestingAR-Gesture] REACH GESTURE DETECTED (\(reason))! Hiding gun...")
        setGunVisible(false)
        isResetPending = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        NotificationCenter.default.post(
            name: .arTestingEvent,
            object: nil,
            userInfo: [BusKey.arevent: AREvent.reachGesture]
        )
    }

    private func currentImageOrientation() -> CGImagePropertyOrientation {
        guard let io = arView.window?.windowScene?.interfaceOrientation else { return .right }
        switch io {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        default: return .right
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
        currentFrameNumber += 1

        let mappingStatus = frame.worldMappingStatus.debugDescription
        if mappingStatus != lastReportedWorldMappingStatus {
            lastReportedWorldMappingStatus = mappingStatus
            DispatchQueue.main.async { [weak self] in
                self?.onWorldMappingStatus?(mappingStatus)
            }
        }

        if let startCameraTransform {
            let status = RoomLibrary.startAlignmentStatus(
                currentCameraTransform: frame.camera.transform,
                targetStartTransform: startCameraTransform
            )
            if status != lastReportedAlignmentStatus {
                lastReportedAlignmentStatus = status
                DispatchQueue.main.async { [weak self] in self?.onAlignmentStatus?(status) }
            }
        } else if lastReportedAlignmentStatus != nil {
            lastReportedAlignmentStatus = nil
            DispatchQueue.main.async { [weak self] in self?.onAlignmentStatus?(nil) }
        }

        // Start marker proximity check
        if isWaitingForStartMarker, let markerPos = startMarkerWorldPos {
            let cam = frame.camera.transform.columns.3
            let dx = cam.x - markerPos.x
            let dz = cam.z - markerPos.z
            if sqrt(dx * dx + dz * dz) <= markerReachDistance {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    print("📍 [TestingAR] Child reached start marker — tap unblocked, marker stays visible until advance")
                    self.isWaitingForStartMarker = false
                    NotificationCenter.default.post(
                        name: .arTestingEvent,
                        object: nil,
                        userInfo: [BusKey.arevent: AREvent.childAtStartMarker]
                    )
                }
            }
        }

        guard placedGunAnchor != nil, !isResetPending else {
            guard !worldMapLoaded else { return }
            let mappingReady: Bool
            switch frame.worldMappingStatus {
            case .mapped, .extending:
                mappingReady = true
            default:
                mappingReady = false
            }

            let alignmentReady: Bool
            if let startCameraTransform {
                let status = RoomLibrary.startAlignmentStatus(
                    currentCameraTransform: frame.camera.transform,
                    targetStartTransform: startCameraTransform
                )
                alignmentReady = status.isAligned
            } else {
                alignmentReady = true
            }

            guard mappingReady, alignmentReady else { return }

            worldMapLoaded = true
            relocalizationTimer?.invalidate()
            print("✅ [TestingAR] Relocalized and aligned — placing testing assets")
            DispatchQueue.main.async { [weak self] in
                self?.placeAssetsForCurrentStage()
                self?.placeStartMarkerIfAvailable()
                self?.onSceneReady?()
            }
            return
        }

        let now = CACurrentMediaTime()
        if now - lastDecisionAt >= decisionInterval {
            lastDecisionAt = now

            if let d = gunDistanceFromCamera(frame: frame) {
                if d < 1.0, wasNear == false {
                    wasNear = true
                    lastNearDistance = d
                }

                if wasNear {
                    let distanceFromNearest = d - lastNearDistance
                    if !isRetreating && distanceFromNearest > retreatStartThreshold {
                        isRetreating = true
                        retreatStartDistance = d
                        retreatStartTime = now
                        print("📍 [TestingAR-Retreat] Retreat started at d=\(String(format: "%.2f", d))m, from closest=\(String(format: "%.2f", lastNearDistance))m")
                    }

                    if isRetreating {
                        let retreatElapsed = now - retreatStartTime
                        let retreatDistance = d - lastNearDistance

                        if retreatDistance > runAwayThreshold {
                            if !isAwaitingSettlement {
                                isAwaitingSettlement = true
                                settlePeakDistance = d
                                lastSignificantMoveTime = now
                                print("📍 [TestingAR-Retreat] Run-away threshold crossed at d=\(String(format: "%.2f", d))m — waiting for child to stop")
                            } else if d > settlePeakDistance + settleThreshold {
                                settlePeakDistance = d
                                lastSignificantMoveTime = now
                            } else if now - lastSignificantMoveTime >= settleTime {
                                wasNear = false
                                isRetreating = false
                                isAwaitingSettlement = false
                                lastNearDistance = 0
                                print("🏃 [TestingAR-Retreat] childRunsAway fired! delta=\(String(format: "%.2f", retreatDistance))m, settled at d=\(String(format: "%.2f", d))m")
                                NotificationCenter.default.post(
                                    name: .arTestingEvent,
                                    object: nil,
                                    userInfo: [BusKey.arevent: AREvent.childRunsAway(delta: retreatDistance, duration: retreatElapsed)]
                                )
                            }
                        }
                    }

                    let previousNearDistance = lastNearDistance
                    lastNearDistance = min(lastNearDistance, d)
                    if lastNearDistance < previousNearDistance && (isRetreating || isAwaitingSettlement) {
                        print("📍 [TestingAR-Retreat] User moved closer (d=\(String(format: "%.2f", d))m) — resetting retreat")
                        isRetreating = false
                        isAwaitingSettlement = false
                    }
                }
            }

            if !isVisionProcessing {
                isVisionProcessing = true
                let capturedImage = frame.capturedImage
                let orientation = currentImageOrientation()
                visionQueue.async { [weak self] in
                    guard let self else { return }
                    do {
                        try self.handRequestHandler.perform([self.handRequest],
                                                            on: capturedImage,
                                                            orientation: orientation)
                    } catch {
                        self.isVisionProcessing = false
                        return
                    }
                    let results = self.handRequest.results ?? []
                    self.observationsLock.lock()
                    self.cachedHandObservations = results
                    self.observationsLock.unlock()
                    self.isVisionProcessing = false
                }
            }

            observationsLock.lock()
            let observations = cachedHandObservations
            observationsLock.unlock()

            if currentFrameNumber % 60 == 0 {
                print("👋 [TestingAR-Gesture] Found \(observations.count) hands")
            }

            if observations.isEmpty {
                overlapReachStreak = 0
            } else if let gunRect = gunScreenRect() {
                if currentFrameNumber % 60 == 0 {
                    print("🎯 [TestingAR-Gesture] Gun rect: \(gunRect)")
                }

                var didHitGunRect = false
                var depthRejectedCount = 0
                for hand in observations {
                    let pts = (try? hand.recognizedPoints(.all)) ?? [:]
                    for key in [VNHumanHandPoseObservation.JointName.indexTip, .middleTip, .wrist] {
                        guard let rp = pts[key], rp.confidence > 0.35 else { continue }
                        let hp = visionNormToScreen(rp.location)

                        if currentFrameNumber % 30 == 0 {
                            print("🖐️ [TestingAR-Gesture] Vision: \(rp.location) → Screen: \(hp), gunRect: \(gunRect), contains: \(gunRect.contains(hp))")
                        }

                        guard gunRect.contains(hp) else { continue }
                        didHitGunRect = true

                        if let depthBuf = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap,
                           let handZ = sampleDepthAtScreen(depthBuf, screenPoint: hp),
                           let gunZ = gunDistanceFromCamera(frame: frame) {
                            let isCloserThanGun = handZ + depthMargin < gunZ
                            let isWithinReachDistance = gunZ - handZ < maxReachDistance
                            print("📏 [TestingAR-Gesture] Depth: handZ=\(String(format: "%.2f", handZ)), gunZ=\(String(format: "%.2f", gunZ)), closer=\(isCloserThanGun), withinReach=\(isWithinReachDistance)")
                            if isCloserThanGun && isWithinReachDistance {
                                triggerReachGesture(reason: "depth gate passed")
                                return
                            } else {
                                depthRejectedCount += 1
                            }
                        }
                    }
                }

                // Sustained overlap fallback (matches stereo mode)
                if didHitGunRect && wasNear {
                    overlapReachStreak += 1
                    if currentFrameNumber % 60 == 0 {
                        print("⚠️ [TestingAR-Gesture] Hand overlapped gun rect — streak \(overlapReachStreak), depthRejected=\(depthRejectedCount)")
                    }
                    if overlapReachStreak >= 3 {
                        let reason = depthRejectedCount > 0
                            ? "sustained overlap fallback with noisy depth"
                            : "sustained overlap fallback"
                        triggerReachGesture(reason: reason)
                        return
                    }
                } else {
                    overlapReachStreak = 0
                }
            } else {
                overlapReachStreak = 0
                if currentFrameNumber % 60 == 0 {
                    print("⚠️ [TestingAR-Gesture] Could not get gun screen rect")
                }
            }
        }

        guard !worldMapLoaded else { return }

        switch frame.worldMappingStatus {
        case .mapped, .extending:
            worldMapLoaded = true
            relocalizationTimer?.invalidate()
            DispatchQueue.main.async { [weak self] in
                self?.placeAssetsForCurrentStage()
                self?.placeStartMarkerIfAvailable()
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
        ZStack {
            Color.black.ignoresSafeArea()
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
        .onTapGesture { onStart() }
    }
}
