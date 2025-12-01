//
//  LiveAudioPlayer.swift
//  Child Gun Safety
//

import Foundation
import AVFoundation

final class LiveAudioPlayer {

    static let shared = LiveAudioPlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let liveFormat: AVAudioFormat

    private init() {
        // Configure audio session for spoken audio playback.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            // print("[Audio] AVAudioSession error:", error)
        }

        // Use a fixed 24 kHz mono float format for live Gemini audio.
        guard let liveFormat = AVAudioFormat(
            standardFormatWithSampleRate: 24_000,
            channels: 1
        ) else {
            fatalError("Could not create liveFormat for LiveAudioPlayer")
        }
        self.liveFormat = liveFormat
        // print("[Audio] liveFormat:", liveFormat)

        engine.attach(player)
        // Connect player -> mainMixer; AVAudioEngine will insert a sample-rate
        // converter from 24 kHz to the hardware rate automatically.
        engine.connect(player, to: engine.mainMixerNode, format: liveFormat)

        do {
            try engine.start()
            // print("[Audio] AVAudioEngine started")
        } catch {
            // print("[Audio] Failed to start engine:", error)
        }
    }

    /// Play a chunk of raw PCM16 mono audio.
    ///
    /// - Parameters:
    ///   - data: Little-endian 16-bit signed mono PCM samples (Gemini Live output).
    ///   - sampleRate: The model’s sample rate (usually 24_000). We ignore it for now
    ///                 and play at the device’s native rate; this may change speed/pitch
    ///                 slightly but avoids crashes.
    func playPCM16(_ data: Data, sampleRate: Double) {
        guard !data.isEmpty else { return }

        let bytesPerSample = MemoryLayout<Int16>.size
        let frameCount = data.count / bytesPerSample
        guard frameCount > 0 else { return }

        // Create a buffer in the live format (float32, deinterleaved).
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: liveFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            // print("[Audio] Failed to create buffer")
            return
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let channelData = buffer.floatChannelData else {
            // print("[Audio] Missing floatChannelData")
            return
        }

        // Convert Int16 mono → Float32 mono in channel 0.
        data.withUnsafeBytes { rawBuffer in
            let src = rawBuffer.bindMemory(to: Int16.self)
            let dst = channelData[0]
            for i in 0..<frameCount {
                dst[i] = Float(src[i]) / Float(Int16.max)
            }
        }

        // If liveFormat has more than one channel, zero the extra channels.
        if liveFormat.channelCount > 1 {
            for ch in 1..<Int(liveFormat.channelCount) {
                memset(
                    channelData[ch],
                    0,
                    Int(frameCount) * MemoryLayout<Float>.size
                )
            }
        }

        if !engine.isRunning {
            do {
                try engine.start()
                // print("[Audio] Engine restarted")
            } catch {
                // print("[Audio] Failed to restart engine:", error)
            }
        }

        if !player.isPlaying {
            player.play()
        }

        // print("[Audio] Scheduling buffer: \(data.count) bytes, \(frameCount) frames (input sr \(sampleRate), liveFormat sr \(liveFormat.sampleRate))")
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    func stop() {
        player.stop()
    }
}
