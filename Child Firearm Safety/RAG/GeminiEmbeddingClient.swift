//
//  GeminiEmbeddingClient.swift
//  Child Firearm Safety
//
//  Created on 2025-02-12.
//

import Foundation

/// REST API client for Gemini text-embedding-004
class GeminiEmbeddingClient {

    private let apiKey: String
    private let baseURL = "https://generativelanguage.googleapis.com/v1/models/text-embedding-004:embedContent"
    private let session: URLSession

    enum EmbeddingError: Error {
        case invalidAPIKey
        case networkError(Error)
        case invalidResponse
        case rateLimitExceeded
        case decodingError(Error)
    }

    init(apiKey: String) {
        self.apiKey = apiKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Embed a single text string
    func embed(_ text: String) async throws -> [Float] {
        let results = try await embedBatch([text])
        guard let first = results.first else {
            throw EmbeddingError.invalidResponse
        }
        return first
    }

    /// Embed multiple texts in a batch (more efficient)
    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        var allEmbeddings: [[Float]] = []

        // Process in chunks of 100 (API limit)
        let chunkSize = 100
        for chunkStart in stride(from: 0, to: texts.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, texts.count)
            let chunk = Array(texts[chunkStart..<chunkEnd])

            let embeddings = try await embedChunk(chunk)
            allEmbeddings.append(contentsOf: embeddings)
        }

        return allEmbeddings
    }

    /// Embed a single chunk (up to 100 texts)
    private func embedChunk(_ texts: [String], retryCount: Int = 0) async throws -> [[Float]] {
        guard !apiKey.isEmpty else {
            throw EmbeddingError.invalidAPIKey
        }

        // Build URL with API key
        guard var urlComponents = URLComponents(string: baseURL) else {
            throw EmbeddingError.invalidResponse
        }
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        guard let url = urlComponents.url else {
            throw EmbeddingError.invalidResponse
        }

        // Build request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Request body - batch format
        let requestBody: [String: Any] = [
            "requests": texts.map { text in
                [
                    "model": "models/text-embedding-004",
                    "content": [
                        "parts": [
                            ["text": text]
                        ]
                    ]
                ]
            }
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        // Make request with retry logic
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw EmbeddingError.invalidResponse
            }

            // Handle rate limiting with exponential backoff
            if httpResponse.statusCode == 429 {
                if retryCount < 3 {
                    let delay = pow(2.0, Double(retryCount))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    return try await embedChunk(texts, retryCount: retryCount + 1)
                } else {
                    throw EmbeddingError.rateLimitExceeded
                }
            }

            guard httpResponse.statusCode == 200 else {
                print("Embedding API error: status \(httpResponse.statusCode)")
                if let responseStr = String(data: data, encoding: .utf8) {
                    print("Response: \(responseStr)")
                }
                throw EmbeddingError.invalidResponse
            }

            // Parse response
            return try parseEmbeddingResponse(data: data)

        } catch let error as EmbeddingError {
            throw error
        } catch {
            throw EmbeddingError.networkError(error)
        }
    }

    /// Parse the Gemini embedding API response
    private func parseEmbeddingResponse(data: Data) throws -> [[Float]] {
        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let embeddings = json?["embeddings"] as? [[String: Any]] else {
                throw EmbeddingError.invalidResponse
            }

            var results: [[Float]] = []
            for embedding in embeddings {
                guard let values = embedding["values"] as? [Double] else {
                    throw EmbeddingError.invalidResponse
                }
                results.append(values.map { Float($0) })
            }

            return results

        } catch {
            throw EmbeddingError.decodingError(error)
        }
    }
}
