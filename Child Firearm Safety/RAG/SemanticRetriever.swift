//
//  SemanticRetriever.swift
//  Child Firearm Safety
//
//  Created on 2025-02-12.
//

import Foundation

/// Embedding-based semantic search with cosine similarity
class SemanticRetriever {

    private let embeddingClient: GeminiEmbeddingClient?

    init(embeddingClient: GeminiEmbeddingClient?) {
        self.embeddingClient = embeddingClient
    }

    /// Retrieve top documents using semantic similarity
    func retrieve(query: String, candidates: [RAGDocument], limit: Int) async throws -> [RAGDocument] {
        try await retrieveRanked(query: query, candidates: candidates, limit: limit)
            .map { $0.document }
    }

    /// Retrieve top documents and scores (for debugging/testing UI)
    func retrieveRanked(query: String, candidates: [RAGDocument], limit: Int) async throws -> [RAGResult] {
        guard let embeddingClient = embeddingClient else {
            throw NSError(domain: "SemanticRetriever", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Embedding client unavailable"
            ])
        }

        // Compute query embedding
        let queryEmbedding = try await embeddingClient.embed(query)

        // Filter candidates that have embeddings
        let candidatesWithEmbeddings = candidates.filter { $0.embedding != nil }

        // Compute cosine similarity for each candidate
        var results: [RAGResult] = []
        for candidate in candidatesWithEmbeddings {
            guard let docEmbedding = candidate.embedding else {
                continue
            }

            let similarity = cosineSimilarity(queryEmbedding, docEmbedding)
            results.append(RAGResult(document: candidate, score: similarity))
        }

        // Sort by similarity and return top N
        return Array(
            results
                .sorted { $0.score > $1.score }
                .prefix(limit)
        )
    }

    /// Compute cosine similarity between two vectors
    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else {
            return 0.0
        }

        var dotProduct: Float = 0.0
        var magnitudeA: Float = 0.0
        var magnitudeB: Float = 0.0

        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            magnitudeA += a[i] * a[i]
            magnitudeB += b[i] * b[i]
        }

        magnitudeA = sqrt(magnitudeA)
        magnitudeB = sqrt(magnitudeB)

        guard magnitudeA > 0 && magnitudeB > 0 else {
            return 0.0
        }

        return dotProduct / (magnitudeA * magnitudeB)
    }
}
