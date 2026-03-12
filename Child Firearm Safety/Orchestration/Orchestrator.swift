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
    private var isProcessingReset: Bool = false
    private var arEventObserver: NSObjectProtocol?
    private var vcIntentObserver: NSObjectProtocol?
    private var verbalPhaseObserver: NSObjectProtocol?
    private var lastReachGestureTime: Date?
    private var tellAdultWorkItem: DispatchWorkItem?

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

        verbalPhaseObserver = NotificationCenter.default.addObserver(
            forName: .verbalPhaseComplete, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleVerbalPhaseComplete()
            }
        }
    }

    deinit {
        // print("🧹 [ORCH \(instanceID)] Orchestrator deinitialized and observers removed")
        if let observer = arEventObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = vcIntentObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = verbalPhaseObserver { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Public lifecyle hooks
    func startSession() {
        phase = .verbalRecitation
        isProcessingReset = false
        // VoiceCoach.startSession() (called by the owning view) handles the scripted intro.
        // Transition to act-out happens when the verbal phase completion tool callback posts .verbalPhaseComplete.
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
        if let observer = verbalPhaseObserver {
            NotificationCenter.default.removeObserver(observer)
            verbalPhaseObserver = nil
        }
    }

    // MARK: - Verbal phase handler
    private func handleVerbalPhaseComplete() {
        guard phase == .verbalRecitation else {
            print("⚠️ [Orchestrator \(instanceID)] verbalPhaseComplete received in unexpected phase: \(phase)")
            return
        }
        print("🎓 [Orchestrator \(instanceID)] Verbal phase complete — waiting for act-out start at marker")
        phase = .awaitingActOutStart
        postARCommand("prepareActOutStart")
        postARCommand("disableTapDuringSpeech")
        say(.transitionToActOut)  // VoiceCoach stores this as pendingActOutInstruction
    }

    // MARK: - Event handlers
    func handleAREvent(_ e: AREvent) {
        // During verbal recitation, only handle reach gestures and tap-to-reset so the LLM
        // is informed and the gun can be restored — all other AR events are ignored.
        if phase == .verbalRecitation {
            switch e {
            case .reachGesture:
                print("🤚 [Orchestrator] Reach gesture during verbalRecitation — notifying LLM")
                postARCommand("showStartMarker")
                say(.coachDontTouchWhy)
            case .userTappedToReset:
                print("👆 [Orchestrator] Tap-to-reset during verbalRecitation — restoring gun")
                postARCommand("setGunVisibility:true")
                say(.resetVerbalRecitation)
            default:
                print("⏭️ [Orchestrator] AR event ignored (still in verbalRecitation): \(e)")
            }
            return
        }
        switch (phase, e) {
        case (.exploration, .gunProximityNear(_)):
            // print("✅ [Orchestrator] Matched: exploration + gunProximityNear")
            lastNearTime = Date()
            phase = .encounterPending
            // print("   Phase changed to: \(phase)")

        case (.encounterPending, .childBacksAway(let delta)) where delta > backAwayDelta:
            print("🏃 [Orchestrator] childBacksAway matched in encounterPending — triggering toTellAdultSoon()")
            phase = .praisePath
            toTellAdultSoon()

        case (.exploration, .childBacksAway(let delta)) where delta > backAwayDelta:
            print("🏃 [Orchestrator] childBacksAway matched in exploration — triggering toTellAdultSoon()")
            phase = .praisePath
            toTellAdultSoon()

        case (.encounterPending, .childRunsAway(_, _)):
            print("🏃 [Orchestrator] childRunsAway matched in encounterPending — triggering toTellAdultSoon()")
            phase = .praisePath
            toTellAdultSoon()

        case (.exploration, .childRunsAway(_, _)):
            print("🏃 [Orchestrator] childRunsAway matched in exploration — triggering toTellAdultSoon()")
            phase = .praisePath
            toTellAdultSoon()

        case (.awaitingActOutStart, .childAtStartMarker), (.exploration, .childAtStartMarker), (.resetLoop, .childAtStartMarker):
            break

        case (.awaitingActOutStart, .userTappedToBeginActOut):
            print("▶️ [Orchestrator] Act-out started from start marker")
            phase = .exploration
            say(.beginActOutScenario)

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
            postARCommand("setGunVisibility:false")
            phase = .resetLoop
            postARCommand("disableTapDuringSpeech")
            postARCommand("showStartMarker")
            say(.instructReset)

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
        case .calledAdult(let text, _):
            print("📢 [Orchestrator] calledAdult VCIntent received — phase=\(phase)")
            if phase == .encounterPending || phase == .exploration {
                phase = .praisePath
                toTellAdultSoon()
            } else if phase == .praisePath {
                // Child called adult spontaneously during the silent window — cancel the prompt timer
                print("🌟 [Orchestrator] Child called adult spontaneously! Cancelling prompt timer.")
                tellAdultWorkItem?.cancel()
                tellAdultWorkItem = nil
                phase = .tellAdultPrompt
                say(.childCalledAdultSpontaneously(text: text))
            }

        case .askedWhatIsThat:
            say(.answerWhatIsThat_safety)

        case .askedIsThatReal:
            say(.answerIsThatReal_safety)

        case .generalQuestion:
            break  // LLM handles naturally via system prompt
        }
    }

    // MARK: - Helpers
    private func toTellAdultSoon() {
        print("⏱️ [Orchestrator] Child ran away — 3s silent window (child may call adult spontaneously)")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            print("⏱️ [Orchestrator] Silent window elapsed — child didn't call adult, prompting now")
            self.phase = .tellAdultPrompt
            self.say(.promptTellAdultPhrase)
            self.tellAdultWorkItem = nil
        }
        tellAdultWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
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
