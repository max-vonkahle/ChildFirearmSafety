//
//  ChildGunSafetyApp.swift
//  Child Gun Safety
//
//  Created by Max on 9/24/25.
//


import SwiftUI
import FirebaseCore

@main
struct ChildGunSafetyApp: App {
    @StateObject private var voiceCoach = VoiceCoach()

    // Scene phase lets us pause/resume audio cleanly
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(voiceCoach)   // if VoiceCoachView reads it via @EnvironmentObject
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // app is foreground: if your VoiceCoach should auto-idle, do nothing here
                break
            case .inactive, .background:
                // be conservative: stop live audio work when leaving foreground
                voiceCoach.stopSession()
            @unknown default:
                break
            }
        }
    }
}
