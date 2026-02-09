//
//  LiveAudioPlayer.swift
//  Child Firearm Safety
//

import Foundation
import AVFoundation

final class LiveAudioPlayer {

    static let shared = LiveAudioPlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let liveFormat: AVAudioFormat

    // Background queue for audio operations to prevent main thread blocking
    private let audioQueue = DispatchQueue(label: "com.childgunsafety.audioplayback", qos: .userInteractive)

    // Peak normalization settings
    private var normalizationEnabled = true
    private let targetPeakLevel: Float = 0.8
    private let minPeakThreshold: Float = 0.05

    // Track scheduled vs completed buffers to know when playback finishes
    private var scheduledBuffers = 0
    private var completedBuffers = 0
    private var playbackCompletionHandler: (() -> Void)?

    private init() {
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

    private func normalizeBuffer(_ buffer: AVAudioPCMBuffer) {
        guard normalizationEnabled else { return }
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        // Find peak amplitude
        var peak: Float = 0.0
        for ch in 0..<channelCount {
            let channel = channelData[ch]
            for i in 0..<frameCount {
                peak = max(peak, abs(channel[i]))
            }
        }

        // Only normalize if peak is significant
        guard peak > minPeakThreshold else { return }

        // Calculate gain with soft limiting
        let gain = targetPeakLevel / peak
        let maxGain: Float = 4.0  // Max 12dB boost
        let effectiveGain = min(gain, maxGain)

        // Apply gain to all channels
        for ch in 0..<channelCount {
            let channel = channelData[ch]
            for i in 0..<frameCount {
                channel[i] *= effectiveGain
            }
        }

        #if DEBUG
        if effectiveGain > 1.5 || effectiveGain < 0.7 {
            print("[Audio] Normalized: peak=\(peak) → gain=\(effectiveGain)x")
        }
        #endif
    }

    /// Play a chunk of raw PCM16 mono audio.
    ///
    /// - Parameters:
    ///   - data: Little-endian 16-bit signed mono PCM samples (Gemini Live output).
    ///   - sampleRate: The model's sample rate (usually 24_000). We ignore it for now
    ///                 and play at the device's native rate; this may change speed/pitch
    ///                 slightly but avoids crashes.
    func playPCM16(_ data: Data, sampleRate: Double) {
        guard !data.isEmpty else { return }

        // Dispatch all audio processing to background queue to avoid blocking main thread
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            let bytesPerSample = MemoryLayout<Int16>.size
            let frameCount = data.count / bytesPerSample
            guard frameCount > 0 else { return }

            // Create a buffer in the live format (float32, deinterleaved).
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: self.liveFormat,
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
            if self.liveFormat.channelCount > 1 {
                for ch in 1..<Int(self.liveFormat.channelCount) {
                    memset(
                        channelData[ch],
                        0,
                        Int(frameCount) * MemoryLayout<Float>.size
                    )
                }
            }

            // Apply peak normalization
            self.normalizeBuffer(buffer)

            if !self.engine.isRunning {
                do {
                    try self.engine.start()
                    // print("[Audio] Engine restarted")
                } catch {
                    // print("[Audio] Failed to restart engine:", error)
                }
            }

            if !self.player.isPlaying {
                self.player.play()
            }

            // print("[Audio] Scheduling buffer: \(data.count) bytes, \(frameCount) frames (input sr \(sampleRate), liveFormat sr \(self.liveFormat.sampleRate))")
            self.scheduledBuffers += 1
            let bufferIndex = self.scheduledBuffers

            self.player.scheduleBuffer(buffer) { [weak self] in
                self?.audioQueue.async {
                    guard let self = self else { return }
                    self.completedBuffers += 1

                    // If all scheduled buffers have completed, call the completion handler
                    if self.completedBuffers == self.scheduledBuffers {
                        if let handler = self.playbackCompletionHandler {
                            // print("[Audio] All buffers complete (\(self.completedBuffers)/\(self.scheduledBuffers)), calling completion")
                            self.playbackCompletionHandler = nil
                            DispatchQueue.main.async {
                                handler()
                            }
                        }
                    }
                }
            }
        }
    }

    /// Set a completion handler to be called when all currently scheduled buffers finish playing
    func onPlaybackComplete(_ handler: @escaping () -> Void) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            // If no buffers are scheduled or all have completed, call immediately
            if self.scheduledBuffers == 0 || self.completedBuffers == self.scheduledBuffers {
                DispatchQueue.main.async {
                    handler()
                }
            } else {
                self.playbackCompletionHandler = handler
            }
        }
    }

    /// Reset buffer tracking for a new audio turn
    func resetForNewTurn() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            self.scheduledBuffers = 0
            self.completedBuffers = 0
            self.playbackCompletionHandler = nil
        }
    }

    func stop() {
        // Stop operations should also be on background queue
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            self.player.stop()
            self.scheduledBuffers = 0
            self.completedBuffers = 0
            self.playbackCompletionHandler = nil
        }
    }
}
