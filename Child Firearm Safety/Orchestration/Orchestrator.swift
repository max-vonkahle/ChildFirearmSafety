//
//  Orchestrator.swift
//  Child Firearm Safety
//
//  Created by Max on 9/25/25.
//


import Foundation
import Combine

@MainActor
final class Orchestrator: ObservableObject {
    @Published private(set) var phase: SessionPhase = .onboarding

    // Tunables
    private let nearDistance: Float = 1.0
    private let backAwayDelta: Float = 0.7

    // Ephemeral state
    private var lastNearTime: Date?
    private var cancellables = Set<AnyCancellable>()
    private var resetAttempts: Int = 0
    private let maxResetAttempts: Int = 3
    private var isProcessingReset: Bool = false
    private var arEventObserver: NSObjectProtocol?
    private var vcIntentObserver: NSObjectProtocol?  // Store second observer for cleanup
    private var lastReachGestureTime: Date?

    // Safety behavior tracking for completion
    private var behaviorTracker = SafetyBehaviorTracker()

    // Unique instance identifier for debugging
    private let instanceID: String

    init() {
        self.instanceID = String(UUID().uuidString.prefix(8))
        // print("🎯 [ORCHESTRATOR INIT] Orchestrator instance created with ID: \(instanceID)")

        // Subscribe to AR + VoiceCoach events via NotificationCenter (TRAINING MODE)
        arEventObserver = NotificationCenter.default.addObserver(
            forName: .arTrainingEvent, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // print("📬 [ORCH \(self.instanceID)] Received .arTrainingEvent notification")
            guard let e = note.userInfo?[BusKey.arevent] as? AREvent else {
                // print("❌ [ORCH \(self.instanceID)] No AR event in notification!")
                return
            }
            // print("📦 [ORCH \(self.instanceID)] Extracted event: \(e)")
            Task { @MainActor in
                self.handleAREvent(e)
            }
        }

        vcIntentObserver = NotificationCenter.default.addObserver(
            forName: .vcIntent, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let i = note.userInfo?[BusKey.vcintent] as? VCIntent else { return }
            Task { @MainActor in
                self.handleVCIntent(i)
            }
        }
    }

    deinit {
        // print("🧹 [ORCH \(instanceID)] Orchestrator deinitialized and observers removed")
        // Clean up observers when Orchestrator is destroyed
        if let observer = arEventObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = vcIntentObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public lifecyle hooks
    func startSession() {
        phase = .onboarding
        resetAttempts = 0
        isProcessingReset = false
        behaviorTracker = SafetyBehaviorTracker()  // Reset behavior tracking
        // Tell voice coach to deliver cover story (no safety reveal)
        say(.coverStoryIntro)
        // After intro, go exploration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.phase = .exploration
            self.promptExploration()
        }
    }

    func stopSession() {
        phase = .wrapup
    }

    /// Explicitly clean up resources - call this when the view disappears
    func cleanup() {
        // print("🧹 [ORCH \(instanceID)] cleanup() called - removing observers")
        if let observer = arEventObserver {
            NotificationCenter.default.removeObserver(observer)
            arEventObserver = nil
        }
        if let observer = vcIntentObserver {
            NotificationCenter.default.removeObserver(observer)
            vcIntentObserver = nil
        }
    }

    // MARK: - Event handlers
    func handleAREvent(_ e: AREvent) {
        // print("📥 [Orchestrator] Received AR event: \(e) in phase: \(phase)")

        // Check if this is a reach gesture specifically
        if case .reachGesture = e {
            // print("🎯 [Orchestrator] This is a REACH GESTURE event!")
            // print("   Current phase: \(phase)")
            // print("   Expected phase: encounterPending")
            // print("   Phase matches: \(phase == .encounterPending)")
        }

        switch (phase, e) {
        case (.exploration, .gunProximityNear(_)):
            // print("✅ [Orchestrator] Matched: exploration + gunProximityNear")
            lastNearTime = Date()
            phase = .encounterPending
            // print("   Phase changed to: \(phase)")

        case (.encounterPending, .childBacksAway(let delta)) where delta > backAwayDelta:
            behaviorTracker.ranAwayPhysically = true
            phase = .praisePath
            say(.praiseBackedAway)
            toReflectionSoon()

        case (.encounterPending, .childRunsAway(let delta, let duration)):
            behaviorTracker.ranAwayPhysically = true
            phase = .praisePath
            say(.praiseRanAway)
            toReflectionSoon()

        case (.encounterPending, .reachGesture), (.exploration, .reachGesture):
            // print("🎯 [Orchestrator] REACH GESTURE detected!")
            // print("   Phase: \(phase) (will auto-transition to encounterPending if needed)")

            // If we're still in exploration, transition to encounterPending first
            // (This happens if user got close during onboarding and proximity event didn't trigger phase change)
            if phase == .exploration {
                // print("   Auto-transitioning from exploration → encounterPending")
                phase = .encounterPending
            }

            // Time-based deduplication (safety net)
            let now = Date()
            if let lastTime = lastReachGestureTime,
               now.timeIntervalSince(lastTime) < 0.5 {
                // print("⏭️ [Orchestrator] Duplicate reach gesture within 0.5s, ignoring")
                return
            }
            lastReachGestureTime = now

            // Prevent duplicate processing
            guard !isProcessingReset else {
                // print("⏭️ [Orchestrator] Already processing reset, ignoring duplicate reach gesture")
                return
            }

            isProcessingReset = true
            resetAttempts += 1
            // print("🔄 [Orchestrator] Processing reach gesture. Attempt \(resetAttempts)/\(maxResetAttempts)")

            // print("📤 [Orchestrator] Posting setGunVisibility:false")
            postARCommand("setGunVisibility:false")

            if resetAttempts < maxResetAttempts {
                // print("📤 [Orchestrator] Setting phase to resetLoop")
                phase = .resetLoop
                postARCommand("disableTapDuringSpeech")  // Disable taps while model speaks
                // print("📤 [Orchestrator] Telling voice coach to say instructReset")
                say(.instructReset)
                // Don't auto-reset - wait for user to tap screen to confirm they're ready
                // print("🔄 [Orchestrator] Waiting for user tap to reset...")
            } else {
                // print("📤 [Orchestrator] Max attempts reached, going to coaching path")
                phase = .coachingPath
                say(.coachDontTouchWhy)
                toReflectionSoon()
            }

        case (.resetLoop, .userTappedToReset):
            // User tapped to confirm they're back at starting position
            // print("✅ [Orchestrator] User tapped to reset - showing gun and returning to exploration")
            // print("   Current state: phase=\(phase), isProcessingReset=\(isProcessingReset)")
            postARCommand("setGunVisibility:true")
            phase = .exploration
            isProcessingReset = false
            lastReachGestureTime = nil  // Reset debounce for next attempt
            say(.postResetEncouragement)  // Guide them through the safety steps
            // print("   New state: phase=\(phase), isProcessingReset=\(isProcessingReset)")

        default:
            break
        }
    }

    func handleVCIntent(_ i: VCIntent) {
        switch i {
        case .calledAdult:
            if phase == .encounterPending || phase == .exploration {
                phase = .praisePath
                say(.praiseBackedAway)
                toReflectionSoon()
            }

        case .askedWhatIsThat:
            say(.answerWhatIsThat_safety)

        case .askedIsThatReal:
            say(.answerIsThatReal_safety)

        case .generalQuestion:
            // keep it neutral; keep exploring
            promptExploration()

        // Verbal explanations of safety rules during reflection
        case .explainedStop:
            // print("✅ [Orchestrator] Child explained 'stop'")
            behaviorTracker.explainedStop = true
            checkForCompletion()

        case .explainedDontTouch:
            // print("✅ [Orchestrator] Child explained 'don't touch'")
            behaviorTracker.explainedDontTouch = true
            checkForCompletion()

        case .explainedRunAway:
            // print("✅ [Orchestrator] Child explained 'run away'")
            behaviorTracker.explainedRunAway = true
            checkForCompletion()

        case .explainedTellAdult:
            // print("✅ [Orchestrator] Child explained 'tell adult'")
            behaviorTracker.explainedTellAdult = true
            checkForCompletion()
        }
    }

    // MARK: - Helpers
    private func toReflectionSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.phase = .reflection
            self.say(.reflectionQ1)
            // Don't auto-transition to wrapup - checkForCompletion will handle that
            // when all behaviors are demonstrated
        }
    }

    private func checkForCompletion() {
        guard phase == .reflection else { return }
        // print("🔍 [Orchestrator] Checking completion: \(behaviorTracker.completedCount)/4 behaviors")

        if behaviorTracker.allBehaviorsComplete {
            // print("🎉 [Orchestrator] All behaviors complete! Triggering training completion")
            phase = .completed
            say(.trainingComplete)
            // Post notification to trigger UI transition to completion screen
            NotificationCenter.default.post(name: .trainingSessionComplete, object: nil)
        }
    }

    // scheduleReset() removed - now using manual tap-to-reset flow

    private func promptExploration() {
        guard phase == .exploration else { return }
        // Rotate a few generic hints; here pass nil or a simple area string
        say(.neutralExplorationPrompt(area: nil))
    }

    // MARK: - Bus senders
    private func say(_ intent: DialogueIntent) {
        // print("📤 [Orchestrator] Posting .vcCommand with intent: \(intent)")
        NotificationCenter.default.post(
            name: .vcCommand,
            object: nil,
            userInfo: [BusKey.dialog: intent]
        )
        // print("✅ [Orchestrator] Posted .vcCommand notification")
    }

    private func postARCommand(_ arg: String) {
        NotificationCenter.default.post(
            name: .arCommand,
            object: nil,
            userInfo: [BusKey.arg: arg]
        )
    }
}
