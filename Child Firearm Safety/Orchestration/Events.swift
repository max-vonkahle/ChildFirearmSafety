//
//  SessionPhase.swift
//  Child Firearm Safety
//
//  Created by Max on 9/25/25.
//


import Foundation

// === Cross-layer events ===
enum SessionPhase {
    case onboarding, exploration, encounterPending, praisePath, coachingPath, resetLoop, reflection, wrapup
}

enum AREvent {
    case gunVisible(distance: Float)
    case gunProximityNear(distance: Float)
    case reachGesture
    case childBacksAway(delta: Float)
    case mappingProgress(percent: Float)
    case userTappedToReset  // User tapped screen to confirm they're back at starting position
}

enum VCIntent {
    case calledAdult(text: String, conf: Float)
    case askedWhatIsThat(text: String, conf: Float)
    case askedIsThatReal(text: String, conf: Float)
    case generalQuestion(text: String)
}

// High-level dialogue commands the coach can speak
enum DialogueIntent {
    case coverStoryIntro
    case neutralExplorationPrompt(area: String?)           // "desk", "window", ...
    case praiseBackedAway
    case coachDontTouchWhy
    case instructReset
    case postResetEncouragement                             // After user taps to reset
    case answerWhatIsThat_safety
    case answerIsThatReal_safety
    case reflectionQ1
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
}

// === Payload keys ===
enum BusKey {
    static let arevent = "AREvent"
    static let vcintent = "VCIntent"
    static let dialog  = "DialogueIntent"
    static let arg     = "Arg" // optional helpers
}
