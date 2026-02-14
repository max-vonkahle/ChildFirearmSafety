//
//  TFIDFRetriever.swift
//  Child Firearm Safety
//
//  Created on 2025-02-12.
//

import Foundation

/// Local keyword-based retrieval using TF-IDF scoring
class TFIDFRetriever {

    // Cache for IDF scores to avoid recomputation
    private var idfCache: [String: Float] = [:]
    private var documentsHash: Int = 0

    /// Retrieve top documents using TF-IDF scoring
    func retrieve(query: String, documents: [RAGDocument], limit: Int = 10) -> [RAGDocument] {
        // Recompute IDF if documents changed
        let currentHash = documents.map { $0.id }.hashValue
        if currentHash != documentsHash {
            idfCache = computeIDF(documents: documents)
            documentsHash = currentHash
        }

        let queryTokens = tokenize(query)
        let results = computeTFIDF(queryTokens: queryTokens, documents: documents)

        return results
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0.document }
    }

    /// Tokenize text into words
    private func tokenize(_ text: String) -> [String] {
        let lowercased = text.lowercased()

        // Remove punctuation and split on whitespace
        let cleaned = lowercased.components(separatedBy: CharacterSet.alphanumerics.inverted)

        // Filter out empty strings and common stop words
        let stopWords = Set(["the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "by", "from", "is", "was", "are", "were", "be", "been", "being", "have", "has", "had", "do", "does", "did", "will", "would", "should", "could", "can", "may", "might", "must"])

        return cleaned.filter { !$0.isEmpty && !stopWords.contains($0) }
    }

    /// Compute IDF (Inverse Document Frequency) for all terms
    private func computeIDF(documents: [RAGDocument]) -> [String: Float] {
        var documentFrequency: [String: Int] = [:]
        let totalDocs = Float(documents.count)

        // Count documents containing each term
        for doc in documents {
            let tokens = Set(tokenize(doc.content + " " + doc.title + " " + doc.tags.joined(separator: " ")))
            for token in tokens {
                documentFrequency[token, default: 0] += 1
            }
        }

        // Compute IDF: log(N / df)
        var idf: [String: Float] = [:]
        for (term, df) in documentFrequency {
            idf[term] = log(totalDocs / Float(df))
        }

        return idf
    }

    /// Compute TF-IDF scores for documents given query tokens
    private func computeTFIDF(queryTokens: [String], documents: [RAGDocument]) -> [RAGResult] {
        var results: [RAGResult] = []

        for doc in documents {
            // Combine all searchable text
            let docText = doc.content + " " + doc.title + " " + doc.tags.joined(separator: " ")
            let docTokens = tokenize(docText)

            // Compute term frequency for this document
            var termFrequency: [String: Float] = [:]
            for token in docTokens {
                termFrequency[token, default: 0] += 1
            }

            // Normalize by document length
            let docLength = Float(docTokens.count)
            for token in termFrequency.keys {
                termFrequency[token] = termFrequency[token]! / docLength
            }

            // Compute TF-IDF score for query
            var score: Float = 0.0
            for queryToken in queryTokens {
                if let tf = termFrequency[queryToken], let idf = idfCache[queryToken] {
                    score += tf * idf
                }
            }

            // Boost if title matches
            let titleTokens = Set(tokenize(doc.title))
            let querySet = Set(queryTokens)
            if !titleTokens.isDisjoint(with: querySet) {
                score *= 1.5
            }

            // Boost if tag matches
            let tagTokens = Set(doc.tags.flatMap { tokenize($0) })
            if !tagTokens.isDisjoint(with: querySet) {
                score *= 1.3
            }

            results.append(RAGResult(document: doc, score: score))
        }

        return results
    }
}
