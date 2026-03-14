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
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50))
                .foregroundColor(.green)

            Text("Great Job!")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text("Training Complete")
                .font(.title3)
                .foregroundColor(.white.opacity(0.9))

            VStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.8))

                Text("Please take off the headset\nand give it to your instructor")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 12)
        }
        .padding(24)
    }
}

#Preview {
    TrainingCompleteView {
        // print("Dismissed")
    }
}
