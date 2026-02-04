//
//  ChildFirearmSafetyApp.swift
//  Child Firearm Safety
//
//  Created by Max on 9/24/25.
//

import SwiftUI
import FirebaseCore

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        FirebaseApp.configure()
        return true
    }
}

@main
struct ChildFirearmSafetyApp: App {
    // Register app delegate for Firebase setup
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    @StateObject private var voiceCoach = VoiceCoach()

    // Scene phase lets us pause/resume audio cleanly
    @Environment(\.scenePhase) private var scenePhase

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
