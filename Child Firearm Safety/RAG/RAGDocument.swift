//
//  RAGDocument.swift
//  Child Firearm Safety
//
//  Created on 2025-02-12.
//

import Foundation

/// Store for all RAG documents and metadata
struct RAGDocumentStore: Codable {
    let documents: [RAGDocument]
    let metadata: RAGMetadata
}

/// Individual coaching guidance document
struct RAGDocument: Codable, Identifiable {
    let id: String
    let title: String
    let content: String
    let category: String
    let tags: [String]
    var embedding: [Float]?

    enum CodingKeys: String, CodingKey {
        case id, title, content, category, tags, embedding
    }
}

/// Metadata about the document collection
struct RAGMetadata: Codable {
    let version: String
    let lastUpdated: String
    let embeddingModel: String?

    enum CodingKeys: String, CodingKey {
        case version
        case lastUpdated = "last_updated"
        case embeddingModel = "embedding_model"
    }
}

/// Mode for RAG retrieval affecting behavior and limits
enum RAGMode: String, CaseIterable, Hashable {
    case training    // During active training sessions
    case testing     // During test mode
    case runtime     // General runtime usage

    var defaultLimit: Int {
        switch self {
        case .training: return 3
        case .testing: return 2
        case .runtime: return 2
        }
    }
}

/// Result from RAG retrieval with score
struct RAGResult {
    let document: RAGDocument
    let score: Float
}
