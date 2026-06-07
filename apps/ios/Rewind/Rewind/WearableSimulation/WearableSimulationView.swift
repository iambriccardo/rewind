//
//  WearableSimulationView.swift
//  Rewind
//
//  Created by Codex on 6/7/26.
//

import Foundation
import SwiftUI

/// Full-screen hands-free simulation of a glasses-style Rewind experience.
///
/// The view owns a dedicated `RewindLiveStore` so entering the simulation starts
/// the live camera, microphone, rolling frame cache, and backend protocol stream
/// immediately. It intentionally avoids visible controls; local speech intent
/// detection drives remembered confirmation, while protocol search events drive
/// retrieval feedback.
struct WearableSimulationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var liveStore: RewindLiveStore
    @State private var confirmation: WearableMemoryConfirmation?
    @State private var snapshotCaptureTriggerID: UUID?
#if os(iOS)
    @State private var rememberSpeechDetector = WearableRememberSpeechDetector()
#endif

    private let automaticallyStartsCapture: Bool
    private let previewConfirmation: WearableMemoryConfirmation?
    private let previewSearchResult: RewindSearchResultCard?

    @State private var confirmationDismissTask: Task<Void, Never>?
#if os(iOS)
    @State private var rememberSpeechIntentTask: Task<Void, Never>?
#endif

    init(
        automaticallyStartsCapture: Bool = true,
        previewConfirmation: WearableMemoryConfirmation? = nil,
        previewSearchResult: RewindSearchResultCard? = nil
    ) {
        self._liveStore = State(initialValue: RewindLiveStore())
        self.automaticallyStartsCapture = automaticallyStartsCapture
        self.previewConfirmation = previewConfirmation
        self.previewSearchResult = previewSearchResult
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            cameraSurface
                .ignoresSafeArea()

            WearableSnapshotCaptureOverlay(
                triggerID: snapshotCaptureTriggerID,
                frame: liveStore.latestCachedFrame,
                previewImageName: automaticallyStartsCapture ? nil : "memory-example-3089"
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            WearableSimulationVignette()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            topRightFeedback
                .allowsHitTesting(false)
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task {
            guard automaticallyStartsCapture else {
                return
            }

            await startWearableExperience()
        }
        .onDisappear {
            confirmationDismissTask?.cancel()
#if os(iOS)
            stopRememberSpeechFeedback()
#endif
            Task {
                await liveStore.stop()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard automaticallyStartsCapture else {
                return
            }

            Task {
                switch phase {
                case .active:
                    await startWearableExperience()
                case .inactive, .background:
#if os(iOS)
                    stopRememberSpeechFeedback()
#endif
                    await liveStore.stop()
                @unknown default:
                    break
                }
            }
        }
        .accessibilityAction(.escape) {
            dismiss()
        }
        .onLongPressGesture(minimumDuration: 1.2) {
            dismiss()
        }
    }

    @ViewBuilder
    private var cameraSurface: some View {
#if os(iOS)
        switch liveStore.captureController.state {
        case .running:
            PhoneCameraPreview(session: liveStore.captureController.previewSession)
        case .failed:
            WearableSimulationFallbackSurface(systemImage: "camera.viewfinder")
        case .idle, .requestingAccess, .stopping:
            if automaticallyStartsCapture {
                Rectangle()
                    .fill(.black)
            } else {
                MemoryImageSurface(imageSource: .asset(name: "memory-example-3027"))
            }
        }
#else
        MemoryImageSurface(imageSource: .asset(name: "memory-example-3027"))
#endif
    }

    private var topRightFeedback: some View {
        GeometryReader { proxy in
            VStack(alignment: .trailing, spacing: 10) {
                if let confirmation = confirmation ?? previewConfirmation {
                    WearableMemoryConfirmationView(confirmation: confirmation)
                        .transition(
                            .move(edge: .top)
                                .combined(with: .scale(scale: 0.9, anchor: .topTrailing))
                                .combined(with: .opacity)
                        )
                }

                if shouldShowSearchFeedback {
                    WearableMemorySearchResultView(
                        query: searchQuery,
                        isSearching: searchIsBusy,
                        result: searchResult,
                        errorMessage: searchError
                    )
                    .transition(
                        .move(edge: .trailing)
                            .combined(with: .scale(scale: 0.9, anchor: .topTrailing))
                            .combined(with: .opacity)
                    )
                }
            }
            .padding(.top, proxy.safeAreaInsets.top + 14)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .animation(.smooth(duration: 0.24), value: confirmation?.id)
        .animation(.smooth(duration: 0.24), value: liveStore.isSearchBusy)
        .animation(.smooth(duration: 0.24), value: liveStore.searchResults.first?.id)
    }

    private var shouldShowSearchFeedback: Bool {
        previewSearchResult != nil
            || liveStore.isSearchBusy
            || liveStore.searchQuery != nil
            || liveStore.searchError != nil
    }

    private var searchQuery: String? {
        previewSearchResult == nil ? liveStore.searchQuery : "Where is the notebook?"
    }

    private var searchIsBusy: Bool {
        previewSearchResult == nil && liveStore.isSearchBusy
    }

    private var searchResult: RewindSearchResultCard? {
        previewSearchResult ?? liveStore.searchResults.first
    }

    private var searchError: String? {
        previewSearchResult == nil ? liveStore.searchError : nil
    }

    private func startWearableExperience() async {
        await liveStore.start()
#if os(iOS)
        await startRememberSpeechFeedback()
#endif
    }

#if os(iOS)
    private func startRememberSpeechFeedback() async {
        await rememberSpeechDetector.start(audioChunks: liveStore.captureController.audioChunks)
        guard rememberSpeechIntentTask == nil else {
            return
        }

        rememberSpeechIntentTask = Task {
            for await _ in rememberSpeechDetector.intents {
                await MainActor.run {
                    showConfirmation()
                }
            }
        }
    }

    private func stopRememberSpeechFeedback() {
        rememberSpeechIntentTask?.cancel()
        rememberSpeechIntentTask = nil
        rememberSpeechDetector.stop()
    }
#endif

    private func showConfirmation() {
        confirmationDismissTask?.cancel()
        confirmation = WearableMemoryConfirmation()
        snapshotCaptureTriggerID = UUID()

        confirmationDismissTask = Task {
            try? await Task.sleep(for: .seconds(2.8))

            await MainActor.run {
                withAnimation(.smooth(duration: 0.22)) {
                    confirmation = nil
                }
            }
        }
    }
}

private struct WearableSimulationVignette: View {
    var body: some View {
        LinearGradient(
            colors: [
                .black.opacity(0.38),
                .clear,
                .clear,
                .black.opacity(0.30)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct WearableSimulationFallbackSurface: View {
    let systemImage: String

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black)

            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .accessibilityHidden(true)
        }
    }
}

#Preview("Wearable Simulation") {
    WearableSimulationView(
        automaticallyStartsCapture: false,
        previewConfirmation: WearableMemoryConfirmation(),
        previewSearchResult: WearableSimulationPreviewData.result
    )
}

#Preview("Wearable Simulation Confirmation") {
    WearableSimulationView(
        automaticallyStartsCapture: false,
        previewConfirmation: WearableMemoryConfirmation()
    )
}

#Preview("Wearable Simulation Retrieval") {
    WearableSimulationView(
        automaticallyStartsCapture: false,
        previewSearchResult: WearableSimulationPreviewData.result
    )
}

#Preview("Wearable Simulation Vignette") {
    ZStack {
        MemoryImageSurface(imageSource: .asset(name: "memory-example-3027"))
            .ignoresSafeArea()

        WearableSimulationVignette()
            .ignoresSafeArea()
    }
    .preferredColorScheme(.dark)
}

#Preview("Wearable Simulation Fallback") {
    WearableSimulationFallbackSurface(systemImage: "camera.viewfinder")
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
}

private enum WearableSimulationPreviewData {
    static let result = RewindSearchResultCard(
        id: "preview-result",
        title: "Notebook on the standing desk",
        description: "The notebook was beside the keyboard near the monitor.",
        entities: ["notebook"],
        locationHint: "standing desk",
        frameURLs: [
            assetFrameURL(named: "memory-example-3081"),
            assetFrameURL(named: "memory-example-3089"),
            assetFrameURL(named: "memory-example-3109")
        ],
        score: 0.86
    )

    private static func assetFrameURL(named imageName: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Assets.xcassets")
            .appendingPathComponent("\(imageName).imageset")
            .appendingPathComponent("\(imageName).jpeg")
    }
}
