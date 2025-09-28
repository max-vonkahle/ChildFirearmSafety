//
//  ASRController.swift
//  Child Gun Safety
//
//  Created by Max on 9/23/25.
//


//
//  ASRController.swift
//  Child Gun Safety
//
//  Created by Max on 9/23/25.
//

import AVFoundation
import Speech

final class ASRController {
    // MARK: - Tunables (endpointing)
    private let partialIdleWindow: TimeInterval = 2.0   // finalize if no new partials for 700ms
    private let maxUtteranceWindow: TimeInterval = 12.0  // hard cap per turn (seconds)

    // Debug RMS (optional)
    private let vadLogFloor: Float = 0.0006             // only log RMS above this

    // MARK: - Speech
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)! // device locale
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    // MARK: - State
    private(set) var isRunning = false
    private var lastPartialText: String = ""
    private var lastPartialChangeAt: TimeInterval = 0
    private var partialIdleTimer: Timer?
    private var maxUtteranceTimer: Timer?

    // “desired state” + debounced restart to avoid racing the speech daemon
    private var wantsRunning: Bool = true
    private var restartWorkItem: DispatchWorkItem?

    // MARK: - Callbacks
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onSpeechStart: (() -> Void)?

    // MARK: - Debug
    var debug = true
    private func log(_ s: String) { if debug { print("[ASR]", s) } }

    // MARK: - Public control
    func setWantsRunning(_ want: Bool) {
        wantsRunning = want
        if !want { // if caller no longer wants running, ensure we stop and cancel pending restarts
            restartWorkItem?.cancel(); restartWorkItem = nil
        }
    }

    func start() throws {
        // Respect desired state
        guard wantsRunning else { log("start() ignored; wantsRunning=false"); return }
        if isRunning { log("start() ignored; already running"); return }

        stop() // cleanup any residue

        // quick permission/status logging, with iOS 17 API
        let permStr: String = {
            if #available(iOS 17.0, *) {
                switch AVAudioApplication.shared.recordPermission {
                case .undetermined: return "undetermined"
                case .denied:       return "denied"
                case .granted:      return "granted"
                @unknown default:   return "unknown"
                }
            } else {
                switch AVAudioSession.sharedInstance().recordPermission {
                case .undetermined: return "undetermined"
                case .denied:       return "denied"
                case .granted:      return "granted"
                @unknown default:   return "unknown"
                }
            }
        }()
        log("recordPermission=\(permStr)")
        log("recognizer available: \(recognizer.isAvailable)")

        // Build request
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = false
        req.taskHint = .dictation
        request = req

        // Install input tap
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.request?.append(buffer)

            // Debug RMS just to prove audio is flowing; NOT used for endpointing.
            let rms = self.bufferRMS(buffer: buffer)
            if rms > self.vadLogFloor {
                self.log(String(format: "rms=%.6f", rms))
            }
        }

        do {
            // (nice-to-have) lower latency
            let sess = AVAudioSession.sharedInstance()
            try? sess.setPreferredSampleRate(44100)
            try? sess.setPreferredIOBufferDuration(0.02)

            engine.prepare()
            try engine.start()
            isRunning = true
            log("engine started, sampleRate=\(fmt.sampleRate), ch=\(fmt.channelCount)")
        } catch {
            log("engine start error: \(error.localizedDescription)")
            throw error
        }

        scheduleMaxUtteranceTimer()

        // Recognition task
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error as NSError? {
                let msg = error.localizedDescription.lowercased()
                if msg.contains("no speech detected") || msg.contains("canceled") {
                    self.log("task info: \(error.localizedDescription)")
                } else {
                    self.log("task error: \(error.localizedDescription)")
                }
                return
            }

            guard let result = result else { return }
            let text = result.bestTranscription.formattedString

            if !text.isEmpty {
                if self.lastPartialText.isEmpty {
                    self.onSpeechStart?()
                }
                if text != self.lastPartialText {
                    self.lastPartialText = text
                    self.lastPartialChangeAt = CACurrentMediaTime()
                    self.onPartial?(text)
                    self.log("partial: \(text)")
                    self.schedulePartialIdleTimer()   // reset inactivity window
                }
            }

            // We finalize via timers (partial idle or max window), not result.isFinal.
        }
    }

    func stop() {
        invalidateTimers()
        restartWorkItem?.cancel(); restartWorkItem = nil

        task?.cancel(); task = nil
        request?.endAudio(); request = nil

        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)

        lastPartialText = ""
        lastPartialChangeAt = 0
        isRunning = false
        log("stopped")
    }

    // MARK: - Endpointing via partial inactivity
    private func schedulePartialIdleTimer() {
        partialIdleTimer?.invalidate()
        partialIdleTimer = Timer.scheduledTimer(withTimeInterval: partialIdleWindow, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            let now = CACurrentMediaTime()
            if now - self.lastPartialChangeAt >= self.partialIdleWindow {
                let final = self.lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !final.isEmpty {
                    self.log("FINAL (idle \(self.partialIdleWindow)s): \"\(final)\"")
                    self.finishUtterance(with: final)
                } else {
                    self.log("idle timer fired but no text; restarting")
                    self.debouncedRestart()
                }
            }
        }
    }

    private func scheduleMaxUtteranceTimer() {
        maxUtteranceTimer?.invalidate()
        maxUtteranceTimer = Timer.scheduledTimer(withTimeInterval: maxUtteranceWindow, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            let final = self.lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !final.isEmpty {
                self.log("FINAL (max \(self.maxUtteranceWindow)s): \"\(final)\"")
                self.finishUtterance(with: final)
            } else {
                self.log("max window but no text; restarting")
                self.debouncedRestart()
            }
        }
    }

    private func finishUtterance(with text: String) {
        onFinal?(text)
        debouncedRestart()
    }

    // MARK: - Debounced restart that respects wantsRunning
    private func debouncedRestart() {
        log("restart()")
        stop()

        // Respect desired state
        guard wantsRunning else {
            log("restart canceled; wantsRunning=false")
            return
        }

        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.wantsRunning else { return }
            try? self.start()
        }
        restartWorkItem = item
        // Small backoff so iOS can tear down the local speech client cleanly
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    private func invalidateTimers() {
        partialIdleTimer?.invalidate(); partialIdleTimer = nil
        maxUtteranceTimer?.invalidate(); maxUtteranceTimer = nil
    }

    // MARK: - RMS (debug only)
    private func bufferRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength); if n == 0 { return 0 }
        var sum: Float = 0
        for i in 0..<n { let v = ch[i]; sum += v * v }
        return sqrt(sum / Float(n))
    }
}
