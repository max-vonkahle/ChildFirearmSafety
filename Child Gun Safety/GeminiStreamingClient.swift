//
//  GeminiStreamingClient.swift
//  Child Gun Safety
//
//  Created by Max on 9/23/25.
//


import Foundation

// Handle you can keep to cancel an in-flight stream (used for barge-in)
final class GeminiStreamHandle {
    fileprivate var task: URLSessionDataTask?
    fileprivate var session: StreamingURLSession?
    func cancel() {
        task?.cancel()
        session?.cancel()
    }
}

final class GeminiStreamingClient {

    // --- API payloads (trimmed to what we need) ---
    struct Part: Codable { let text: String? }
    struct Content: Codable { let role: String?; let parts: [Part]? }
    struct Candidate: Codable { let content: Content? }
    struct StreamResponse: Codable { let candidates: [Candidate]? }

    private let apiKey: String
    private let model: String
    private let base = "https://generativelanguage.googleapis.com/v1beta"

    init(apiKey: String = (Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String) ?? "",
         model: String = "gemini-2.5-flash") {
        self.apiKey = apiKey
        self.model = model
    }

    struct StreamHandlers {
        var onOpen: (() -> Void)?
        var onToken: ((String) -> Void)?      // raw text deltas
        var onSentence: ((String) -> Void)?   // sentence-sized chunks (good for TTS)
        var onDone: (() -> Void)?
        var onError: ((Error) -> Void)?
    }

    private var sentenceBuffer = ""

    /// Open a streaming request and return a handle you can cancel.
    @discardableResult
    func stream(userText: String,
                systemPrompt: String? = nil,
                temperature: Double = 0.2,
                handlers: StreamHandlers) -> GeminiStreamHandle {

        let handle = GeminiStreamHandle()

        guard !apiKey.isEmpty else {
            handlers.onError?(NSError(domain: "Gemini", code: 0,
                                      userInfo: [NSLocalizedDescriptionKey: "Missing API key"]))
            return handle
        }

        // Build request body
        struct GenCfg: Codable { let temperature: Double? }
        struct BPart: Codable { let text: String }
        struct BContent: Codable { let role: String; let parts: [BPart] }
        struct Body: Codable {
            let contents: [BContent]
            let systemInstruction: BContent?
            let generationConfig: GenCfg?
        }

        let sys = systemPrompt.map { BContent(role: "user", parts: [BPart(text: $0)]) }
        let body = Body(
            contents: [BContent(role: "user", parts: [BPart(text: userText)])],
            systemInstruction: sys,
            generationConfig: GenCfg(temperature: temperature)
        )

        // --- IMPORTANT: alt=sse and Accept header ---
        var comps = URLComponents(string: "\(base)/models/\(model):streamGenerateContent")!
        comps.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "alt", value: "sse")
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONEncoder().encode(body)

        // Open the SSE stream
        let s = StreamingURLSession.shared
        let task = s.open(
            req: req,
            onOpen: { handlers.onOpen?() },
            onEvent: { [weak self] line in
                // Expect lines like: "data: { ...json... }"
                guard line.hasPrefix("data:") else { return }
                let jsonStr = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard jsonStr != "[DONE]" else { return }

                guard let data = jsonStr.data(using: .utf8) else { return }

                // 1) Try the typed decode first
                if let obj = try? JSONDecoder().decode(StreamResponse.self, from: data),
                   let text = obj.candidates?.first?.content?.parts?.first?.text,
                   !text.isEmpty {
                    handlers.onToken?(text)
                    self?.emitSentences(from: text, onSentence: handlers.onSentence)
                    return
                }

                // 2) Fallback: generic JSON parse to surface errors or alternative shapes
                do {
                    if let any = try JSONSerialization.jsonObject(with: data) as? [String: Any] {

                        // Surface API errors immediately
                        if let error = any["error"] as? [String: Any] {
                            let msg = (error["message"] as? String) ?? "Unknown API error"
                            handlers.onError?(NSError(domain: "Gemini", code: 1,
                                                      userInfo: [NSLocalizedDescriptionKey: msg]))
                            return
                        }

                        // Some frames may include safety or usage without text; ignore those.
                        if let cands = any["candidates"] as? [[String: Any]],
                           let content = cands.first?["content"] as? [String: Any],
                           let parts = content["parts"] as? [[String: Any]],
                           let text = parts.first?["text"] as? String,
                           !text.isEmpty {
                            handlers.onToken?(text)
                            self?.emitSentences(from: text, onSentence: handlers.onSentence)
                            return
                        }

                        // Debug unexpected payloads so you can see what's coming back
                        #if DEBUG
                        print("[SSE] non-text frame:", any)
                        #endif
                    }
                } catch {
                    #if DEBUG
                    print("[SSE] JSON parse error:", error, "raw:", jsonStr)
                    #endif
                }
            },
            onClose: { [weak self] in
                if let tail = self?.sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines),
                   !tail.isEmpty {
                    handlers.onSentence?(tail)
                }
                handlers.onDone?()
            },
            onError: { handlers.onError?($0) }
        )

        handle.task = task
        handle.session = s
        return handle
    }

    // Split incoming text into sentences for nicer TTS
    private func emitSentences(from chunk: String, onSentence: ((String)->Void)?) {
        sentenceBuffer.append(chunk)
        let pattern = #"([\.!\?])(\s|\z)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        while true {
            if let m = regex.firstMatch(in: sentenceBuffer, range: NSRange(location: 0, length: sentenceBuffer.utf16.count)) {
                let end = m.range.location + m.range.length
                let idx = sentenceBuffer.index(sentenceBuffer.startIndex, offsetBy: end)
                let sentence = String(sentenceBuffer[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { onSentence?(sentence) }
                sentenceBuffer = String(sentenceBuffer[idx...])
            } else {
                break
            }
        }
    }
}

/// Delegate-based URLSession that surfaces SSE `data:` lines.
final class StreamingURLSession: NSObject, URLSessionDataDelegate {
    static let shared = StreamingURLSession()

    private var session: URLSession!
    private var onOpen: (() -> Void)?
    private var onEvent: ((String) -> Void)?
    private var onClose: (() -> Void)?
    private var onError: ((Error) -> Void)?
    private var buffer = Data()

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    /// Start streaming; returns the underlying task so callers can cancel if needed.
    @discardableResult
    func open(req: URLRequest,
              onOpen: @escaping () -> Void,
              onEvent: @escaping (String) -> Void,
              onClose: @escaping () -> Void,
              onError: @escaping (Error) -> Void) -> URLSessionDataTask {

        self.onOpen = onOpen
        self.onEvent = onEvent
        self.onClose = onClose
        self.onError = onError

        let task = session.dataTask(with: req)
        task.resume()
        return task
    }

    /// Cancel active work (used by barge-in)
    func cancel() {
        session.invalidateAndCancel()
        // rebuild a fresh session so future calls still work
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        buffer.removeAll(keepingCapacity: false)
    }

    // MARK: URLSessionDataDelegate
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if buffer.isEmpty { onOpen?() }
        buffer.append(data)

        // Split on LF '\n' and emit each line
        while let range = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                onEvent?(line)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error { onError?(error) }
        onClose?()
        // reset callbacks
        onOpen = nil; onEvent = nil; onClose = nil; onError = nil
        buffer.removeAll(keepingCapacity: false)
    }
}
