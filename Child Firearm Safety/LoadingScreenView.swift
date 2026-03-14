//
//  LoadingScreenView.swift
//  Child Firearm Safety
//
//  Created by Max on 1/13/26.
//

import SwiftUI

struct LoadingDebugInfo {
    var mappingStatus: String
    var detailLines: [String] = []
}

struct LoadingScreenView: View {
    var message: String = "Loading your training environment..."
    var onExit: (() -> Void)? = nil
    var debugInfo: LoadingDebugInfo? = nil
    @AppStorage("cardboardMode") private var cardboardMode = false
    @State private var showExitButton = false

    var body: some View {
        ZStack {
            // Fully opaque background to hide camera feed during loading
            Color.black
                .edgesIgnoringSafeArea(.all)

            if cardboardMode {
                // Stereo mode: duplicate content for left and right eyes
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        // Left eye
                        VStack(spacing: 20) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.5)
                            Text(message)
                                .font(.headline)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        .frame(width: geometry.size.width / 2, height: geometry.size.height)

                        // Right eye
                        VStack(spacing: 20) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.5)
                            Text(message)
                                .font(.headline)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        .frame(width: geometry.size.width / 2, height: geometry.size.height)
                    }
                }
            } else {
                // Normal mode
                VStack(spacing: 20) {
                    // Loading indicator
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)

                    // Loading message
                    Text(message)
                        .font(.headline)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }

            if let debugInfo {
                VStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("Mapping: \(debugInfo.mappingStatus)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                        ForEach(debugInfo.detailLines, id: \.self) { line in
                            Text(line)
                                .font(.footnote)
                                .foregroundColor(.white.opacity(0.85))
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, cardboardMode ? 64 : 24)
                    .padding(.bottom, 48)
                }
            }

            if let onExit, showExitButton {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: onExit) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(0.12), in: Circle())
                        }
                        .padding(.top, cardboardMode ? 44 : 20)
                        .padding(.trailing, 20)
                    }
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard onExit != nil else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                showExitButton.toggle()
            }
        }
    }
}

struct HeadsetInstructionView: View {
    var onContinue: () -> Void

    var body: some View {
        ZStack {
            Color.black
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 20) {
                Text("Put your phone into the cardboard headset")
                    .font(.headline)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Image(systemName: "eye.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
                    .opacity(0.8)

                Button("Continue") {
                    onContinue()
                }
                .font(.headline)
                .foregroundColor(.blue)
                .padding()
                .background(Color.white.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

struct StartTrainingPromptView: View {
    @AppStorage("cardboardMode") private var cardboardMode = false
    var onTap: () -> Void

    var body: some View {
        ZStack {
            // Fully opaque background to keep camera hidden until tap
            Color.black
                .edgesIgnoringSafeArea(.all)

            if cardboardMode {
                // Stereo mode: duplicate content for left and right eyes
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        // Left eye
                        VStack(spacing: 20) {
                            Text("Tap anywhere to begin the training")
                                .font(.headline)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.white)
                                .opacity(0.8)
                        }
                        .frame(width: geometry.size.width / 2, height: geometry.size.height)

                        // Right eye
                        VStack(spacing: 20) {
                            Text("Tap anywhere to begin the training")
                                .font(.headline)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.white)
                                .opacity(0.8)
                        }
                        .frame(width: geometry.size.width / 2, height: geometry.size.height)
                    }
                }
            } else {
                // Normal mode
                VStack(spacing: 20) {
                    // Prompt message
                    Text("Tap anywhere to begin the training")
                        .font(.headline)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    // Visual indicator
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.white)
                        .opacity(0.8)
                }
            }
        }
        .onTapGesture {
            onTap()
        }
    }
}
