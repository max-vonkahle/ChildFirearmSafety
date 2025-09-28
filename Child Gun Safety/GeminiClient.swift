//
//  GeminiClient.swift
//  Child Gun Safety
//
//  Created by Max on 9/23/25.
//


import Foundation

struct GeminiClient {
    static let shared = GeminiClient()
    private let apiKey: String = (Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String) ?? ""

    // Use Flash for speed & free-tier friendliness
    private let model = "gemini-2.5-flash"
    private let base = "https://generativelanguage.googleapis.com/v1beta"

    struct Part: Codable { let text: String }
    struct Content: Codable { let role: String; let parts: [Part] }
    struct GenerationConfig: Codable {
        let temperature: Double?
        let topP: Double?
        let topK: Int?
        let candidateCount: Int?
    }
    struct GenerateContentRequest: Codable {
        let contents: [Content]
        let systemInstruction: Content?
        let generationConfig: GenerationConfig?
    }
    struct Candidate: Codable { let content: Content? }
    struct GenerateContentResponse: Codable { let candidates: [Candidate]? }

    /// Simple one-turn chat. Returns the assistant’s text (or throws).
    func chat(userText: String, systemPrompt: String? = nil) async throws -> String {
        guard !apiKey.isEmpty else { throw NSError(domain: "Gemini", code: 0, userInfo: [NSLocalizedDescriptionKey: "Missing API key"]) }

        var comps = URLComponents(string: "\(base)/models/\(model):generateContent")!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let sys: Content? = systemPrompt.map { Content(role: "user", parts: [Part(text: $0)]) } // Google calls it systemInstruction; content uses role strings.
        let body = GenerateContentRequest(
            contents: [Content(role: "user", parts: [Part(text: userText)])],
            systemInstruction: sys,
            generationConfig: GenerationConfig(temperature: 0.2, topP: nil, topK: nil, candidateCount: 1)
        )

        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let txt = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "Gemini", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "API error: \(txt)"])
        }

        let decoded = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
        let text = decoded.candidates?.first?.content?.parts.first?.text
        return text ?? ""
    }
}
