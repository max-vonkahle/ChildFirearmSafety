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

    // Unique instance identifier for debugging
    private let instanceID: String

    init() {
        self.instanceID = String(UUID().uuidString.prefix(8))
        print("🎯 [ORCHESTRATOR INIT] Orchestrator instance created with ID: \(instanceID)")

        // Subscribe to AR + VoiceCoach events via NotificationCenter (TRAINING MODE)
        arEventObserver = NotificationCenter.default.addObserver(
            forName: .arTrainingEvent, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            print("📬 [ORCH \(self.instanceID)] Received .arTrainingEvent notification")
            guard let e = note.userInfo?[BusKey.arevent] as? AREvent else { return }
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
        print("🧹 [ORCH \(instanceID)] Orchestrator deinitialized and observers removed")
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
        print("🧹 [ORCH \(instanceID)] cleanup() called - removing observers")
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
        print("📥 [Orchestrator] Received AR event: \(e) in phase: \(phase)")
        switch (phase, e) {
        case (.exploration, .gunProximityNear(_)):
            lastNearTime = Date()
            phase = .encounterPending

        case (.encounterPending, .childBacksAway(let delta)) where delta > backAwayDelta:
            phase = .praisePath
            say(.praiseBackedAway)
            toReflectionSoon()

        case (.encounterPending, .reachGesture):
            // Time-based deduplication (safety net)
            let now = Date()
            if let lastTime = lastReachGestureTime,
               now.timeIntervalSince(lastTime) < 0.5 {
                print("⏭️ [Orchestrator] Duplicate reach gesture within 0.5s, ignoring")
                return
            }
            lastReachGestureTime = now

            // Prevent duplicate processing
            guard !isProcessingReset else {
                print("⏭️ [Orchestrator] Already processing reset, ignoring duplicate reach gesture")
                return
            }

            isProcessingReset = true
            resetAttempts += 1
            print("🔄 [Orchestrator] Processing reach gesture. Attempt \(resetAttempts)/\(maxResetAttempts)")

            postARCommand("setGunVisibility:false")

            if resetAttempts < maxResetAttempts {
                phase = .resetLoop
                postARCommand("disableTapDuringSpeech")  // Disable taps while model speaks
                say(.instructReset)
                // Don't auto-reset - wait for user to tap screen to confirm they're ready
                print("🔄 [Orchestrator] Waiting for user tap to reset...")
            } else {
                phase = .coachingPath
                say(.coachDontTouchWhy)
                toReflectionSoon()
            }

        case (.resetLoop, .userTappedToReset):
            // User tapped to confirm they're back at starting position
            print("✅ [Orchestrator] User tapped to reset - showing gun and returning to exploration")
            print("   Current state: phase=\(phase), isProcessingReset=\(isProcessingReset)")
            postARCommand("setGunVisibility:true")
            phase = .exploration
            isProcessingReset = false
            lastReachGestureTime = nil  // Reset debounce for next attempt
            say(.postResetEncouragement)  // Guide them through the safety steps
            print("   New state: phase=\(phase), isProcessingReset=\(isProcessingReset)")

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
        }
    }

    // MARK: - Helpers
    private func toReflectionSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.phase = .reflection
            self.say(.reflectionQ1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.phase = .wrapup
            }
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
        print("📤 [Orchestrator] Posting .vcCommand with intent: \(intent)")
        NotificationCenter.default.post(
            name: .vcCommand,
            object: nil,
            userInfo: [BusKey.dialog: intent]
        )
        print("✅ [Orchestrator] Posted .vcCommand notification")
    }

    private func postARCommand(_ arg: String) {
        NotificationCenter.default.post(
            name: .arCommand,
            object: nil,
            userInfo: [BusKey.arg: arg]
        )
    }
}
