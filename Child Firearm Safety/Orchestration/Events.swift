//
//  SessionPhase.swift
//  Child Firearm Safety
//
//  Created by Max on 9/25/25.
//


import Foundation

// === Cross-layer events ===
enum SessionPhase {
    case verbalRecitation                                                                           // Phase 1: child recites rules before AR encounter
    case onboarding, exploration, encounterPending, praisePath, coachingPath, resetLoop, reflection, completed, wrapup
    case tellAdultPrompt                                                                            // Post-runaway: child says tell-adult phrase
}

enum AREvent {
    case gunVisible(distance: Float)
    case gunProximityNear(distance: Float)
    case reachGesture
    case childBacksAway(delta: Float)
    case childRunsAway(delta: Float, duration: TimeInterval)  // Faster/further retreat than backing away
    case mappingProgress(percent: Float)
    case userTappedToReset  // User tapped screen to confirm they're back at starting position
}

enum VCIntent {
    case calledAdult(text: String, conf: Float)
    case askedWhatIsThat(text: String, conf: Float)
    case askedIsThatReal(text: String, conf: Float)
    case generalQuestion(text: String)
    // Verbal explanations of safety rules during reflection
    case explainedStop(text: String, conf: Float)
    case explainedDontTouch(text: String, conf: Float)
    case explainedRunAway(text: String, conf: Float)
    case explainedTellAdult(text: String, conf: Float)
}

// High-level dialogue commands the coach can speak
enum DialogueIntent {
    case coverStoryIntro
    case neutralExplorationPrompt(area: String?)           // "desk", "window", ...
    case praiseBackedAway
    case praiseRanAway                                      // Enthusiastic praise for running away
    case coachDontTouchWhy
    case instructReset
    case postResetEncouragement                             // After user taps to reset
    case answerWhatIsThat_safety
    case answerIsThatReal_safety
    case reflectionQ1
    case trainingComplete                                   // All safety behaviors demonstrated
    case transitionToActOut                                 // Inject Phase 2 context after verbal phase
    case promptTellAdultPhrase                              // After running away, ask child to say tell-adult phrase
}

// === Safety behavior tracking for completion ===
struct SafetyBehaviorTracker {
    var explainedStop: Bool = false           // Verbally explained "stop"
    var explainedDontTouch: Bool = false      // Verbally explained "don't touch"
    var ranAwayPhysically: Bool = false       // Physically ran/backed away
    var explainedRunAway: Bool = false        // Verbally explained "run away"
    var explainedTellAdult: Bool = false      // Verbally explained "tell adult"

    // Run away can be physical OR verbal
    var runAwayComplete: Bool {
        ranAwayPhysically || explainedRunAway
    }

    var allBehaviorsComplete: Bool {
        explainedStop && explainedDontTouch && runAwayComplete && explainedTellAdult
    }

    var completedCount: Int {
        [explainedStop, explainedDontTouch, runAwayComplete, explainedTellAdult].filter { $0 }.count
    }
}

// === Notification names (quick bus you already use) ===
extension Notification.Name {
    // AR → Orchestrator (TRAINING MODE ONLY)
    static let arTrainingEvent = Notification.Name("arTrainingEvent")

    // AR → TestingOrchestrator (TESTING MODE ONLY)
    static let arTestingEvent = Notification.Name("arTestingEvent")

    // AR → Orchestrator (DEPRECATED - use arTrainingEvent or arTestingEvent)
    static let arEvent = Notification.Name("arEvent")

    // VoiceCoach → Orchestrator
    static let vcIntent = Notification.Name("vcIntent")

    // Orchestrator → AR
    static let arCommand = Notification.Name("arCommand")

    // Orchestrator → VoiceCoach
    static let vcCommand = Notification.Name("vcCommand")

    // Training session completion
    static let verbalPhaseComplete = Notification.Name("verbalPhaseComplete")
    static let trainingSessionComplete = Notification.Name("trainingSessionComplete")
    static let testingStageComplete = Notification.Name("testingStageComplete")
    static let testingSessionComplete = Notification.Name("testingSessionComplete")
}

// === Payload keys ===
enum BusKey {
    static let arevent = "AREvent"
    static let vcintent = "VCIntent"
    static let dialog  = "DialogueIntent"
    static let arg     = "Arg" // optional helpers
}
