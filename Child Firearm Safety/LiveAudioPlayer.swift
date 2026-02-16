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
    // TOGGLE THIS: Set to false to disable normalization and use raw model audio
    private var normalizationEnabled = false  // Disabled - raw model audio sounds better with earbuds
    private let targetPeakLevel: Float = 0.8
    private let minPeakThreshold: Float = 0.00001  // Lowered to -100dB to catch extremely quiet model output

    // Track scheduled vs completed buffers to know when playback finishes
    private var scheduledBuffers = 0
    private var completedBuffers = 0
    private var playbackCompletionHandler: (() -> Void)?

    // Audio level statistics for current turn
    private var turnStats = AudioTurnStats()

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

        // Track statistics
        turnStats.totalBuffers += 1
        turnStats.peakLevels.append(peak)

        // Only normalize if peak is significant
        guard peak > minPeakThreshold else {
            turnStats.skippedBuffers += 1
            return
        }

        // Calculate gain with soft limiting
        let gain = targetPeakLevel / peak
        let maxGain: Float = 6.0  // Max 15.6dB boost - higher values create fuzzy artifacts
        let effectiveGain = min(gain, maxGain)

        // Track gain stats
        turnStats.gainsApplied.append(effectiveGain)

        // Apply gain to all channels
        for ch in 0..<channelCount {
            let channel = channelData[ch]
            for i in 0..<frameCount {
                channel[i] *= effectiveGain
            }
        }
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

            // Only log when engine needs restart (indicates a problem)
            if !self.engine.isRunning {
                print("⚠️ [Audio] Engine was stopped! Restarting...")
                do {
                    try self.engine.start()
                } catch {
                    print("❌ [Audio] Failed to restart engine: \(error)")
                }
            }

            if !self.player.isPlaying {
                self.player.play()
            }
            self.scheduledBuffers += 1
            let bufferIndex = self.scheduledBuffers

            self.player.scheduleBuffer(buffer) { [weak self] in
                self?.audioQueue.async {
                    guard let self = self else { return }
                    self.completedBuffers += 1

                    // If all scheduled buffers have completed, call the completion handler
                    if self.completedBuffers == self.scheduledBuffers {
                        if let handler = self.playbackCompletionHandler {
                            self.printTurnSummary()
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
            self.turnStats = AudioTurnStats()
        }
    }

    private func printTurnSummary() {
        #if DEBUG
        guard turnStats.totalBuffers > 0 else { return }

        let peaks = turnStats.peakLevels
        let gains = turnStats.gainsApplied

        let minPeak = peaks.min() ?? 0
        let maxPeak = peaks.max() ?? 0
        let avgPeak = peaks.reduce(0, +) / Float(peaks.count)

        let minPeakDB = minPeak > 0 ? 20 * log10(minPeak) : -100.0
        let maxPeakDB = maxPeak > 0 ? 20 * log10(maxPeak) : -100.0
        let avgPeakDB = avgPeak > 0 ? 20 * log10(avgPeak) : -100.0

        // Categorize buffers by level
        let veryQuiet = peaks.filter { $0 < 0.01 }.count  // < -40dB
        let quiet = peaks.filter { $0 >= 0.01 && $0 < 0.1 }.count  // -40dB to -20dB
        let normal = peaks.filter { $0 >= 0.1 && $0 < 0.5 }.count  // -20dB to -6dB
        let loud = peaks.filter { $0 >= 0.5 }.count  // > -6dB

        var summary = """

        🔊 [Audio Turn Summary]
        📊 Buffers: \(turnStats.totalBuffers) total, \(turnStats.skippedBuffers) skipped
        📈 Peak levels: min=\(String(format: "%.4f", minPeak)) (\(String(format: "%.1f", minPeakDB))dB), max=\(String(format: "%.4f", maxPeak)) (\(String(format: "%.1f", maxPeakDB))dB), avg=\(String(format: "%.4f", avgPeak)) (\(String(format: "%.1f", avgPeakDB))dB)
        📊 Distribution: \(veryQuiet) very quiet (<-40dB), \(quiet) quiet (-40 to -20dB), \(normal) normal (-20 to -6dB), \(loud) loud (>-6dB)
        """

        if !gains.isEmpty {
            let minGain = gains.min() ?? 1.0
            let maxGain = gains.max() ?? 1.0
            let avgGain = gains.reduce(0, +) / Float(gains.count)
            let minGainDB = 20 * log10(minGain)
            let maxGainDB = 20 * log10(maxGain)
            let avgGainDB = 20 * log10(avgGain)

            summary += """

            🎚️ Gain applied: min=\(String(format: "%.1f", minGain))x (\(String(format: "%.1f", minGainDB))dB), max=\(String(format: "%.1f", maxGain))x (\(String(format: "%.1f", maxGainDB))dB), avg=\(String(format: "%.1f", avgGain))x (\(String(format: "%.1f", avgGainDB))dB)
            """
        }

        print(summary)
        #endif
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

// MARK: - Audio Statistics

private struct AudioTurnStats {
    var totalBuffers: Int = 0
    var skippedBuffers: Int = 0
    var peakLevels: [Float] = []
    var gainsApplied: [Float] = []
}
