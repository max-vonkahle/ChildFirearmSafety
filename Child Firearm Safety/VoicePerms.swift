//
//  VoicePerms.swift
//  Child Firearm Safety
//
//  Created by Max on 9/23/25.
//

import AVFoundation
import Speech

enum VoicePerms {

    /// Configure the audio session for duplex voice (speaker + mic).
    static func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        try session.setActive(true)
    }

    /// Request speech recognition permission (async wrapper).
    static func requestSpeech() async throws {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { s in cont.resume(returning: s) }
        }
        guard status == .authorized else {
            throw NSError(domain: "ASR", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Speech permission denied (\(status))"])
        }
    }

    /// Request microphone permission (iOS 17+ compatible).
    static func requestMicrophone() async throws {
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { ok in
                    cont.resume(returning: ok)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    cont.resume(returning: ok)
                }
            }
        }
        guard granted else {
            throw NSError(domain: "ASR", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
        }
    }
    
    static func setModeListening() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord,
                           mode: .measurement,                   // good for ASR
                           options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        try? s.setActive(true, options: [.notifyOthersOnDeactivation])
    }

    static func setModeSpeaking() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord,
                           mode: .spokenAudio,                   // good for TTS
                           options: [.defaultToSpeaker, .allowBluetooth])
        try? s.setActive(true, options: [.notifyOthersOnDeactivation])
    }

}

