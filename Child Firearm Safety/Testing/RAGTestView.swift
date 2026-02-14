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
                        testRetrieval(mode: .training, limit: 3)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Test Semantic") {
                        testRetrieval(mode: .runtime, limit: 2)
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

    private func testRetrieval(mode: RAGMode, limit: Int) {
        isLoading = true
        results = "Retrieving..."

        Task {
            let start = Date()
            let context = await RAGService.shared.retrieveContext(
                for: query,
                mode: mode,
                limit: limit
            )
            let elapsed = Date().timeIntervalSince(start)

            await MainActor.run {
                results = """
                Query: \(query)
                Mode: \(mode)
                Limit: \(limit)
                Time: \(String(format: "%.3f", elapsed))s

                \(context)
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
