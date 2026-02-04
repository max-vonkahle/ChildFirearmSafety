//
//  LoadingScreenView.swift
//  Child Firearm Safety
//
//  Created by Max on 1/13/26.
//

import SwiftUI
struct LoadingScreenView: View {
    @AppStorage("cardboardMode") private var cardboardMode = false

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
                            Text("Loading your training environment...")
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
                            Text("Loading your training environment...")
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
                    Text("Loading your training environment...")
                        .font(.headline)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
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
