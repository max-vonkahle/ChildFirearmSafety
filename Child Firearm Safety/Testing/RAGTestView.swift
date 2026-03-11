//
//  RAGTestView.swift
//  Child Firearm Safety
//
//  Created on 2025-02-12.
//

import SwiftUI

struct RAGTestView: View {
    @State private var query: String = "child reached for gun"
    @State private var results: String = ""
    @State private var isLoading = false
    @State private var cacheStats: String = ""
    @State private var testMode: RAGMode = .runtime
    @State private var testLimit: Int = 3

    var body: some View {
        VStack(spacing: 20) {
            Text("RAG System Test")
                .font(.title)
                .padding()

            // Query input
            VStack(alignment: .leading, spacing: 8) {
                Text("Test Query:")
                    .font(.headline)

                TextField("Enter query...", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                HStack(spacing: 12) {
                    Button("Test TF-IDF") {
                        testRetrieval(forcing: .tfidf)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Test Semantic") {
                        testRetrieval(forcing: .semantic)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Clear Cache") {
                        RAGService.shared.clearCaches()
                        cacheStats = "Query cache cleared"
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .disabled(isLoading)

                HStack(spacing: 12) {
                    Picker("Mode", selection: $testMode) {
                        Text("Runtime").tag(RAGMode.runtime)
                        Text("Training").tag(RAGMode.training)
                        Text("Testing").tag(RAGMode.testing)
                    }
                    .pickerStyle(.segmented)

                    Stepper("Limit: \(testLimit)", value: $testLimit, in: 1...10)
                        .frame(maxWidth: 140)
                }
                .padding(.horizontal)
            }

            // Cache stats
            Text(cacheStats)
                .font(.caption)
                .foregroundColor(.secondary)

            // Results
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Results:")
                        .font(.headline)

                    if isLoading {
                        ProgressView("Retrieving...")
                    } else {
                        Text(results.isEmpty ? "No results yet" : results)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
        .onAppear {
            updateCacheStats()
        }
    }

    private func testRetrieval(forcing backend: RAGRetrievalBackend) {
        isLoading = true
        results = "Retrieving..."

        Task {
            // Re-read API key if the user changed it in Settings without restarting the app.
            RAGService.shared.refreshEmbeddingClient()
            let start = Date()
            let debug = await RAGService.shared.retrieveDebugContext(
                for: query,
                mode: testMode,
                limit: testLimit,
                forceBackend: backend
            )
            let elapsed = Date().timeIntervalSince(start)

            await MainActor.run {
                let rankedLines = debug.results.enumerated().map { index, result in
                    "\(index + 1). score=\(String(format: "%.4f", result.score)) | \(result.document.title)"
                }.joined(separator: "\n")

                results = """
                Query: \(query)
                Mode: \(String(describing: testMode))
                Limit: \(testLimit)
                Requested Backend: \(debug.requestedBackend.rawValue)
                Used Backend: \(debug.usedBackend.rawValue)
                Fallback: \(debug.fallbackReason ?? "None")
                Time: \(String(format: "%.3f", elapsed))s

                Ranked Results:
                \(rankedLines.isEmpty ? "(none)" : rankedLines)

                \(debug.formattedContext)
                """
                isLoading = false
                updateCacheStats()
            }
        }
    }

    private func updateCacheStats() {
        cacheStats = RAGService.shared.getCacheStats()
    }
}

#Preview {
    RAGTestView()
}
