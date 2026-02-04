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
     @Binding var selectedAsset: String?
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
         selectedAsset: Binding<String?>? = nil,
         onDisarm: @escaping () -> Void,
         onSceneAppear: (() -> Void)? = nil,
         onSceneTap: (() -> Void)? = nil,
         onExit: (() -> Void)? = nil,
         @ViewBuilder overlay: @escaping () -> Overlay) {
        _isArmed = isArmed
        _clearTick = clearTick
        if let selectedAsset = selectedAsset {
            _selectedAsset = selectedAsset
        } else {
            _selectedAsset = .constant(nil)
        }
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
                                selectedAssetBinding: $selectedAsset,
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
        .overlay(alignment: .topTrailing) {
            Group {
                if showExitUI, let onExit {
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
                    .padding(.top, 44)
                    .padding(.trailing, 16)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showExitUI)
        }
        .onDisappear {
            cleanupExitAutoHide()
        }
    }
}

extension ARSceneView where Overlay == EmptyView {
    init(isArmed: Binding<Bool>,
         clearTick: Binding<Int>,
         selectedAsset: Binding<String?>? = nil,
         onDisarm: @escaping () -> Void,
         onSceneAppear: (() -> Void)? = nil,
         onSceneTap: (() -> Void)? = nil,
         onExit: (() -> Void)? = nil) {
        self.init(isArmed: isArmed,
                  clearTick: clearTick,
                  selectedAsset: selectedAsset,
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
