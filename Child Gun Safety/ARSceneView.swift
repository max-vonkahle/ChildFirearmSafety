//
//  ARSceneView.swift
//  Child Gun Safety
//
//  Shared stereo-capable AR scene used by Setup and Safety Training flows.
//

import SwiftUI

struct ARSceneView<Overlay: View>: View {
    @Binding var isArmed: Bool
    @Binding var clearTick: Int
    var onDisarm: () -> Void
    var onSceneAppear: (() -> Void)? = nil
    var onSceneTap: (() -> Void)? = nil
    @ViewBuilder var overlay: () -> Overlay

    @AppStorage("cardboardMode") private var cardboardMode = false

    init(isArmed: Binding<Bool>,
         clearTick: Binding<Int>,
         onDisarm: @escaping () -> Void,
         onSceneAppear: (() -> Void)? = nil,
         onSceneTap: (() -> Void)? = nil,
         @ViewBuilder overlay: @escaping () -> Overlay) {
        _isArmed = isArmed
        _clearTick = clearTick
        self.onDisarm = onDisarm
        self.onSceneAppear = onSceneAppear
        self.onSceneTap = onSceneTap
        self.overlay = overlay
    }

    var body: some View {
        ZStack {
            if cardboardMode {
                StereoARContainer()
                    .ignoresSafeArea()
                    .scaleEffect(0.98)
                CardboardOverlay()
                    .ignoresSafeArea()
            } else {
                ARViewContainer(isArmed: $isArmed,
                                clearTick: $clearTick,
                                onDisarm: onDisarm)
                    .ignoresSafeArea()
            }
        }
        .onAppear { onSceneAppear?() }
        .simultaneousGesture(
            TapGesture().onEnded { onSceneTap?() }
        )
        .overlay(alignment: .bottom) {
            overlay()
        }
    }
}

extension ARSceneView where Overlay == EmptyView {
    init(isArmed: Binding<Bool>,
         clearTick: Binding<Int>,
         onDisarm: @escaping () -> Void,
         onSceneAppear: (() -> Void)? = nil,
         onSceneTap: (() -> Void)? = nil) {
        self.init(isArmed: isArmed,
                  clearTick: clearTick,
                  onDisarm: onDisarm,
                  onSceneAppear: onSceneAppear,
                  onSceneTap: onSceneTap) {
            EmptyView()
        }
    }
}
