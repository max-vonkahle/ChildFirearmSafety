//
//  AudioSessionManager.swift
//  Child Firearm Safety
//

import AVFoundation

final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private init() {}

    enum Mode {
        case playbackOnly    // Gemini speaking
        case duplexVoice     // Mic + playback
    }

    private var currentMode: Mode?

    func configure(for mode: Mode) throws {
        guard currentMode != mode else { return }

        let session = AVAudioSession.sharedInstance()

        switch mode {
        case .playbackOnly:
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        case .duplexVoice:
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        }

        try session.setActive(true, options: [])
        currentMode = mode

        #if DEBUG
        print("[AudioSession] Configured for \(mode)")
        #endif
    }

    func deactivate() {
        let session = AVAudioSession.sharedInstance()
        if !session.isOtherAudioPlaying {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            currentMode = nil
        }
    }
}
