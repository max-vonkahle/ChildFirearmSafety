//
//  LiveAudioPlayer.swift
//  Child Gun Safety
//
//  Created by OpenAI Assistant.
//

import Foundation
import AVFoundation

@MainActor
final class LiveAudioPlayer {
    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?

    private(set) var isPlaying: Bool = false

    func play(pcm: Data, sampleRate: Double) throws {
        guard !pcm.isEmpty else { return }

        stop()

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: true) else {
            throw NSError(domain: "LiveAudioPlayer",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Unable to allocate audio format"])
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let frameLength = UInt32(pcm.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            throw NSError(domain: "LiveAudioPlayer",
                          code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unable to allocate audio buffer"])
        }
        buffer.frameLength = frameLength

        pcm.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            buffer.int16ChannelData?.pointee.update(from: source, count: Int(frameLength))
        }

        try engine.start()
        player.play()

        isPlaying = true
        onStart?()

        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.onFinish?()
                self.stop()
            }
        }

        self.engine = engine
        self.player = player
        self.format = format
    }

    func stop() {
        player?.stop()
        engine?.stop()
        engine?.reset()
        player = nil
        engine = nil
        format = nil
        isPlaying = false
    }
}
