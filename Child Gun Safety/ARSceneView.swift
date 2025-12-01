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
    var onExit: (() -> Void)? = nil
    @ViewBuilder var overlay: () -> Overlay

    @AppStorage("cardboardMode") private var cardboardMode = false
    @State private var showExitUI = false
    @State private var exitAutoHideTask: Task<Void, Never>? = nil

    init(isArmed: Binding<Bool>,
         clearTick: Binding<Int>,
         onDisarm: @escaping () -> Void,
         onSceneAppear: (() -> Void)? = nil,
         onSceneTap: (() -> Void)? = nil,
         onExit: (() -> Void)? = nil,
         @ViewBuilder overlay: @escaping () -> Overlay) {
        _isArmed = isArmed
        _clearTick = clearTick
        self.onDisarm = onDisarm
        self.onSceneAppear = onSceneAppear
        self.onSceneTap = onSceneTap
        self.onExit = onExit
        self.overlay = overlay
    }

    var body: some View {
        ZStack {
            if cardboardMode {
                StereoARContainer()
                    .ignoresSafeArea()
                    .scaleEffect(0.98)
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
            TapGesture().onEnded { handleTap() }
        )
        .overlay(alignment: .bottom) {
            overlay()
        }
        .safeAreaInset(edge: .top) {
            Group {
                if showExitUI, let onExit {
                    HStack {
                        Spacer()
                        Button {
                            cleanupExitAutoHide()
                            onExit()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28, weight: .bold))
                                .padding(16)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Exit to Home")
                        .transition(.opacity.combined(with: .scale))
                    }
                    .padding(.top, 32)
                    .padding(.trailing, 16)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showExitUI)
            .zIndex(1000)
        }
        .onDisappear {
            cleanupExitAutoHide()
        }
    }
}

extension ARSceneView where Overlay == EmptyView {
    init(isArmed: Binding<Bool>,
         clearTick: Binding<Int>,
         onDisarm: @escaping () -> Void,
         onSceneAppear: (() -> Void)? = nil,
         onSceneTap: (() -> Void)? = nil,
         onExit: (() -> Void)? = nil) {
        self.init(isArmed: isArmed,
                  clearTick: clearTick,
                  onDisarm: onDisarm,
                  onSceneAppear: onSceneAppear,
                  onSceneTap: onSceneTap,
                  onExit: onExit) {
            EmptyView()
        }
    }
}

@MainActor
private extension ARSceneView {
    func handleTap() {
        onSceneTap?()
        guard onExit != nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            showExitUI = true
        }
        scheduleExitAutoHide()
    }

    func scheduleExitAutoHide() {
        exitAutoHideTask?.cancel()
        exitAutoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                showExitUI = false
            }
            exitAutoHideTask = nil
        }
    }

    func cleanupExitAutoHide() {
        exitAutoHideTask?.cancel()
        exitAutoHideTask = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            showExitUI = false
        }
    }
}
