//
//  HomeView.swift
//  Child Gun Safety
//
//  Created by Max on 9/23/25.
//


import SwiftUI

struct HomeView: View {
    @State private var cardboardMode = false
    @StateObject private var cardboardFit = CardboardFit()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Child Gun Safety")
                    .font(.largeTitle).bold()

                Text("Choose a mode to begin")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Toggle("Cardboard Viewer Mode", isOn: $cardboardMode)
                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                    .padding(.horizontal)

                Menu {
                    NavigationLink {
                        ContentView(mode: .create, cardboardMode: $cardboardMode)
                    } label: {
                        Label("Create Room (place gun)", systemImage: "plus.circle")
                    }
                    NavigationLink {
                        ContentView(mode: .load, cardboardMode: $cardboardMode)
                    } label: {
                        Label("Load Room", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("AR Training", systemImage: "arkit")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                NavigationLink {
                    OrchestratorView()
                } label: {
                    Label("Start Safety Session (Voice + AR)", systemImage: "ear.and.waveform")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.purple.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Spacer()
            }
            .padding()
        }
        .environmentObject(cardboardFit)
    }
}
