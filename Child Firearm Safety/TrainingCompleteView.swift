//
//  TrainingCompleteView.swift
//  Child Firearm Safety
//
//  Created by Max on 2/14/26.
//

import SwiftUI

struct TrainingCompleteView: View {
    @AppStorage("cardboardMode") private var cardboardMode = false
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Semi-transparent background to partially show AR scene
            Color.black.opacity(0.85)
                .edgesIgnoringSafeArea(.all)

            if cardboardMode {
                // Stereo mode: duplicate content for left and right eyes
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        // Left eye
                        completionContent
                            .frame(width: geometry.size.width / 2, height: geometry.size.height)

                        // Right eye
                        completionContent
                            .frame(width: geometry.size.width / 2, height: geometry.size.height)
                    }
                }
            } else {
                // Normal mode
                completionContent
            }
        }
        .onTapGesture {
            onDismiss()
        }
    }

    private var completionContent: some View {
        VStack(spacing: 24) {
            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)

            // Completion message
            Text("Great Job!")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text("Training Complete")
                .font(.title2)
                .foregroundColor(.white.opacity(0.9))

            // Instruction to return headset
            VStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.white.opacity(0.8))

                Text("Please take off the headset\nand give it to your instructor")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)
        }
        .padding(40)
    }
}

#Preview {
    TrainingCompleteView {
        // print("Dismissed")
    }
}
