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

    // Removed app-level VoiceCoach - each view creates its own instance
    // This prevents duplicate notification processing

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
