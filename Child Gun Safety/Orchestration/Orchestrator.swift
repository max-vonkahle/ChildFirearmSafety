//
//  Orchestrator.swift
//  Child Gun Safety
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

    init() {
        // Subscribe to AR + VoiceCoach events via NotificationCenter
        NotificationCenter.default.addObserver(
            forName: .arEvent, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let e = note.userInfo?[BusKey.arevent] as? AREvent else { return }
            self.handleAREvent(e)
        }

        NotificationCenter.default.addObserver(
            forName: .vcIntent, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let i = note.userInfo?[BusKey.vcintent] as? VCIntent else { return }
            self.handleVCIntent(i)
        }
    }

    // MARK: - Public lifecyle hooks
    func startSession() {
        phase = .onboarding
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

    // MARK: - Event handlers
    func handleAREvent(_ e: AREvent) {
        switch (phase, e) {
        case (.exploration, .gunProximityNear(let d)):
            lastNearTime = Date()
            phase = .encounterPending

        case (.encounterPending, .childBacksAway(let delta)) where delta > backAwayDelta:
            phase = .praisePath
            say(.praiseBackedAway)
            toReflectionSoon()

        case (.encounterPending, .reachGesture):
            // Hide gun; coach corrective
            postARCommand("setGunVisibility:false")
            phase = .coachingPath
            say(.coachDontTouchWhy)
            toReflectionSoon()

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

    private func promptExploration() {
        guard phase == .exploration else { return }
        // Rotate a few generic hints; here pass nil or a simple area string
        say(.neutralExplorationPrompt(area: nil))
    }

    // MARK: - Bus senders
    private func say(_ intent: DialogueIntent) {
        NotificationCenter.default.post(
            name: .vcCommand,
            object: nil,
            userInfo: [BusKey.dialog: intent]
        )
    }

    private func postARCommand(_ arg: String) {
        NotificationCenter.default.post(
            name: .arCommand,
            object: nil,
            userInfo: [BusKey.arg: arg]
        )
    }
}