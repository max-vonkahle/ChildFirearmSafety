//
//  RAGService.swift
//  Child Firearm Safety
//
//  Created on 2025-02-12.
//

import Foundation

/// Main service orchestrating RAG retrieval pipeline
class RAGService {

    static let shared = RAGService()

    private var documents: [RAGDocument] = []
    private var metadata: RAGMetadata?

    private let tfidfRetriever = TFIDFRetriever()
    private var semanticRetriever: SemanticRetriever?

    private var embeddingClient: GeminiEmbeddingClient?

    // In-memory cache for recent queries
    private var queryCache: [String: String] = [:]
    private let queryCacheLimit = 50

    private init() {
        setupEmbeddingClient()
        loadDocuments()
    }

    /// Setup embedding client using API key from UserDefaults
    private func setupEmbeddingClient() {
        if let apiKey = UserDefaults.standard.string(forKey: "gemini_api_key"), !apiKey.isEmpty {
            embeddingClient = GeminiEmbeddingClient(apiKey: apiKey)
            semanticRetriever = SemanticRetriever(embeddingClient: embeddingClient)
            // print("RAGService: Embedding client initialized")
        } else {
            // print("RAGService: No API key found, using TF-IDF only")
            semanticRetriever = SemanticRetriever(embeddingClient: nil)
        }
    }

    /// Load documents from bundle RAGDocuments.json
    private func loadDocuments() {
        guard let url = Bundle.main.url(forResource: "RAGDocuments", withExtension: "json") else {
            // print("RAGService: RAGDocuments.json not found in bundle")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let store = try decoder.decode(RAGDocumentStore.self, from: data)

            documents = store.documents
            metadata = store.metadata

            // print("RAGService: Loaded \(documents.count) documents (version \(store.metadata.version))")

        } catch {
            // print("RAGService: Failed to load documents: \(error)")
        }
    }

    /// Main retrieval pipeline
    func retrieveContext(for query: String, mode: RAGMode = .runtime, limit: Int? = nil) async -> String {
        // Check query cache first
        let cacheKey = "\(query)_\(mode)_\(limit ?? mode.defaultLimit)"
        if let cached = queryCache[cacheKey] {
            return cached
        }

        guard !documents.isEmpty else {
            return ""
        }

        let effectiveLimit = limit ?? mode.defaultLimit

        // Step 1: TF-IDF filter to top 10 candidates
        let tfidfCandidates = tfidfRetriever.retrieve(
            query: query,
            documents: documents,
            limit: min(10, documents.count)
        )

        // Step 2: Semantic rerank if available
        let finalDocuments: [RAGDocument]
        if let semanticRetriever = semanticRetriever, embeddingClient != nil {
            do {
                finalDocuments = try await semanticRetriever.retrieve(
                    query: query,
                    candidates: tfidfCandidates,
                    limit: effectiveLimit
                )
            } catch {
                // print("RAGService: Semantic retrieval failed, falling back to TF-IDF: \(error)")
                finalDocuments = Array(tfidfCandidates.prefix(effectiveLimit))
            }
        } else {
            // Fall back to TF-IDF only
            finalDocuments = Array(tfidfCandidates.prefix(effectiveLimit))
        }

        // Step 3: Format as coaching guidance
        let formattedContext = formatContext(documents: finalDocuments, mode: mode)

        // Cache result
        queryCache[cacheKey] = formattedContext
        if queryCache.count > queryCacheLimit {
            // Simple cache eviction: remove random entry
            if let randomKey = queryCache.keys.randomElement() {
                queryCache.removeValue(forKey: randomKey)
            }
        }

        return formattedContext
    }

    /// Format retrieved documents as coaching guidance text
    private func formatContext(documents: [RAGDocument], mode: RAGMode) -> String {
        guard !documents.isEmpty else {
            return ""
        }

        var context = "COACHING GUIDANCE:\n\n"

        for (index, doc) in documents.enumerated() {
            context += "\(index + 1). \(doc.title)\n"
            context += "\(doc.content)\n\n"
        }

        // Add mode-specific instructions
        switch mode {
        case .training:
            context += "Apply these guidelines during this training session."
        case .testing:
            context += "Use these principles during testing, being supportive and educational."
        case .runtime:
            context += "Incorporate these coaching principles naturally in your response."
        }

        return context
    }

    /// Reload documents (useful after updates)
    func reloadDocuments() {
        loadDocuments()
    }

    /// Get cache statistics
    func getCacheStats() -> String {
        let docsWithEmbeddings = documents.filter { $0.embedding != nil }.count
        return """
        RAG Stats:
        - Total documents: \(documents.count)
        - Documents with embeddings: \(docsWithEmbeddings)
        - In-memory query cache: \(queryCache.count) entries
        """
    }

    /// Clear query cache
    func clearCaches() {
        queryCache.removeAll()
        // print("RAGService: Query cache cleared")
    }
}
