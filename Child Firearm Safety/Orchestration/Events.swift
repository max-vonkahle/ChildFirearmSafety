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
    case onboarding, awaitingActOutStart, exploration, encounterPending, praisePath, resetLoop, completed, wrapup
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
    case userTappedToBeginActOut  // User tapped screen at the start marker to begin Phase 2
    case childAtStartMarker  // Child walked to the red X floor marker
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
    case praiseBackedAway
    case praiseRanAway                                      // Enthusiastic praise for running away
    case coachDontTouchWhy
    case instructReset
    case resetVerbalRecitation                              // After reset during Phase 1, ask child to repeat the 4 steps
    case postResetEncouragement                             // After user taps to reset
    case answerWhatIsThat_safety
    case answerIsThatReal_safety
    case trainingComplete                                   // All safety behaviors demonstrated
    case transitionToActOut                                 // Inject Phase 2 context after verbal phase
    case beginActOutScenario                                // Spoken kickoff after the child taps to begin Phase 2
    case promptTellAdultPhrase                              // After running away, LLM prompts child to say tell-adult phrase
    case childCalledAdultSpontaneously(text: String)        // Child called adult unprompted during silent window
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

    // Setup: place/clear start marker at device feet
    static let placeStartMarker = Notification.Name("placeStartMarker")
    static let clearStartMarker = Notification.Name("clearStartMarker")
    // Setup: world mapping status changed (userInfo key: "isReady" Bool)
    static let mappingStatusChanged = Notification.Name("mappingStatusChanged")

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
