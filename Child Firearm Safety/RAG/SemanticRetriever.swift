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
        guard let embeddingClient = embeddingClient else {
            // No embedding client available, return candidates as-is
            return Array(candidates.prefix(limit))
        }

        // Compute query embedding
        let queryEmbedding = try await embeddingClient.embed(query)

        // Filter candidates that have embeddings
        let candidatesWithEmbeddings = candidates.filter { $0.embedding != nil }

        // Compute cosine similarity for each candidate
        var results: [(document: RAGDocument, score: Float)] = []
        for candidate in candidatesWithEmbeddings {
            guard let docEmbedding = candidate.embedding else {
                continue
            }

            let similarity = cosineSimilarity(queryEmbedding, docEmbedding)
            results.append((document: candidate, score: similarity))
        }

        // Sort by similarity and return top N
        return results
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0.document }
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
