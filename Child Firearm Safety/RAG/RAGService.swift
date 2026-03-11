//
//  RAGService.swift
//  Child Firearm Safety
//
//  Created on 2025-02-12.
//

import Foundation

enum RAGRetrievalBackend: String {
    case tfidf = "TF-IDF"
    case semantic = "Semantic"
}

struct RAGRetrievalDebugResult {
    let requestedBackend: RAGRetrievalBackend
    let usedBackend: RAGRetrievalBackend
    let fallbackReason: String?
    let results: [RAGResult]
    let formattedContext: String
}

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
        embeddingClient = nil
        semanticRetriever = nil

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

    /// Expands a short query into a richer context string for semantic embedding.
    /// TF-IDF uses the raw query; semantic search benefits from more document-like phrasing.
    private func expandQuery(_ query: String) -> String {
        """
        Context: A child is participating in an AR firearm safety training simulation. \
        A voice coach is guiding the child through safe behaviors when encountering an unsupervised firearm. \
        Relevant research topic: \(query)
        """
    }

    /// Main retrieval pipeline
    func retrieveContext(for query: String, mode: RAGMode = .runtime, limit: Int? = nil) async -> String {
        let effectiveLimit = limit ?? mode.defaultLimit
        let useTFIDF = UserDefaults.standard.bool(forKey: "ragUseTFIDF")
        let semanticAvailable = embeddingClient != nil

        // Check query cache first (include retrieval strategy state to avoid stale collisions)
        let cacheKey = "\(query)_\(mode)_\(effectiveLimit)_tfidf:\(useTFIDF)_semanticAvailable:\(semanticAvailable)"
        if let cached = queryCache[cacheKey] {
            return cached
        }

        guard !documents.isEmpty else {
            return ""
        }

        let finalDocuments: [RAGDocument]
        if useTFIDF {
            // TF-IDF only mode: fully local, no API calls — use raw query for keyword matching
            finalDocuments = tfidfRetriever.retrieve(
                query: query,
                documents: documents,
                limit: effectiveLimit
            )
        } else if let semanticRetriever = semanticRetriever, embeddingClient != nil {
            // Semantic: expand query with context before embedding
            let expandedQuery = expandQuery(query)
            do {
                finalDocuments = try await semanticRetriever.retrieve(
                    query: expandedQuery,
                    candidates: documents,
                    limit: effectiveLimit
                )
            } catch {
                // print("RAGService: Semantic retrieval failed, falling back to TF-IDF: \(error)")
                finalDocuments = tfidfRetriever.retrieve(
                    query: query,
                    documents: documents,
                    limit: effectiveLimit
                )
            }
        } else {
            // No API key set, fall back to TF-IDF
            finalDocuments = tfidfRetriever.retrieve(
                query: query,
                documents: documents,
                limit: effectiveLimit
            )
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

    /// Force a specific backend and return debugging details (used by RAG test UI).
    func retrieveDebugContext(
        for query: String,
        mode: RAGMode = .runtime,
        limit: Int? = nil,
        forceBackend: RAGRetrievalBackend
    ) async -> RAGRetrievalDebugResult {
        let effectiveLimit = limit ?? mode.defaultLimit

        guard !documents.isEmpty else {
            return RAGRetrievalDebugResult(
                requestedBackend: forceBackend,
                usedBackend: .tfidf,
                fallbackReason: "No RAG documents loaded",
                results: [],
                formattedContext: ""
            )
        }

        switch forceBackend {
        case .tfidf:
            let ranked = tfidfRetriever.retrieveRanked(
                query: query,
                documents: documents,
                limit: effectiveLimit
            )
            return RAGRetrievalDebugResult(
                requestedBackend: .tfidf,
                usedBackend: .tfidf,
                fallbackReason: nil,
                results: ranked,
                formattedContext: formatContext(documents: ranked.map(\.document), mode: mode)
            )

        case .semantic:
            guard let semanticRetriever = semanticRetriever, embeddingClient != nil else {
                let ranked = tfidfRetriever.retrieveRanked(
                    query: query,
                    documents: documents,
                    limit: effectiveLimit
                )
                return RAGRetrievalDebugResult(
                    requestedBackend: .semantic,
                    usedBackend: .tfidf,
                    fallbackReason: "Semantic unavailable (missing Gemini API key or embedding client not initialized).",
                    results: ranked,
                    formattedContext: formatContext(documents: ranked.map(\.document), mode: mode)
                )
            }

            let expandedQuery = expandQuery(query)
            do {
                let ranked = try await semanticRetriever.retrieveRanked(
                    query: expandedQuery,
                    candidates: documents,
                    limit: effectiveLimit
                )
                return RAGRetrievalDebugResult(
                    requestedBackend: .semantic,
                    usedBackend: .semantic,
                    fallbackReason: nil,
                    results: ranked,
                    formattedContext: formatContext(documents: ranked.map(\.document), mode: mode)
                )
            } catch {
                let ranked = tfidfRetriever.retrieveRanked(
                    query: query,
                    documents: documents,
                    limit: effectiveLimit
                )
                return RAGRetrievalDebugResult(
                    requestedBackend: .semantic,
                    usedBackend: .tfidf,
                    fallbackReason: "Semantic failed and fell back to TF-IDF: \(error.localizedDescription)",
                    results: ranked,
                    formattedContext: formatContext(documents: ranked.map(\.document), mode: mode)
                )
            }
        }
    }

    /// Re-read API key and rebuild embedding client after Settings changes.
    func refreshEmbeddingClient() {
        setupEmbeddingClient()
        clearCaches()
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
        let hasAPIKey = !(UserDefaults.standard.string(forKey: "gemini_api_key") ?? "").isEmpty
        return """
        RAG Stats:
        - Total documents: \(documents.count)
        - Documents with embeddings: \(docsWithEmbeddings)
        - Gemini API key set: \(hasAPIKey ? "Yes" : "No")
        - Semantic client initialized: \(embeddingClient != nil ? "Yes" : "No")
        - In-memory query cache: \(queryCache.count) entries
        """
    }

    /// Clear query cache
    func clearCaches() {
        queryCache.removeAll()
        // print("RAGService: Query cache cleared")
    }
}
