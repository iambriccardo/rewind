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
/// immediately. It intentionally avoids visible controls; backend save and search
/// protocol events drive the top-right wearable feedback components.
struct WearableSimulationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var liveStore: RewindLiveStore
    @State private var confirmation: WearableMemoryConfirmation?
    @State private var snapshotCaptureTriggerID: UUID?

    private let automaticallyStartsCapture: Bool
    private let previewConfirmation: WearableMemoryConfirmation?
    private let previewSearchResult: RewindSearchResultCard?

    @State private var confirmationDismissTask: Task<Void, Never>?

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

            if shouldShowRecordingGlow {
                WearableRecordingEdgeGlow()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            wearableBackButton
                .padding(.top, 32)
                .ignoresSafeArea()

            topRightResult
                .padding(.top, 32)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            bottomCenterFeedback
                .ignoresSafeArea()
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
                    await liveStore.stop()
                @unknown default:
                    break
                }
            }
        }
        .onChange(of: liveStore.status) { _, status in
            handleLiveStatusChange(status)
        }
        .accessibilityAction(.escape) {
            dismiss()
        }
        .onLongPressGesture(minimumDuration: 1.2) {
            dismiss()
        }
    }

    private var wearableBackButton: some View {
        GeometryReader { proxy in
            WearableSimulationBackButton {
                dismiss()
            }
            .padding(.top, proxy.safeAreaInsets.top + 14)
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private var topRightResult: some View {
        GeometryReader { proxy in
            VStack(alignment: .trailing, spacing: 10) {
                if shouldShowSearchResultCarousel {
                    WearableSearchResultCarouselView(
                        query: searchQuery,
                        statusText: searchStatusText,
                        results: searchResults
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
        .animation(.smooth(duration: 0.24), value: searchResults.map(\.id).joined(separator: "-"))
    }

    private var bottomCenterFeedback: some View {
        GeometryReader { proxy in
            VStack(spacing: 8) {
                Spacer()

                if let confirmation = confirmation ?? previewConfirmation {
                    WearableMemoryConfirmationView(confirmation: confirmation)
                        .transition(.wearableBottomText)
                } else if searchIsBusy {
                    WearableStatusTextChip(text: searchProgressText)
                        .transition(.wearableBottomText)
                } else if let searchError {
                    WearableStatusTextChip(text: searchError)
                        .transition(.wearableBottomText)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, proxy.safeAreaInsets.bottom + 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .animation(.smooth(duration: 0.34), value: confirmation?.id)
        .animation(.smooth(duration: 0.34), value: liveStore.isSearchBusy)
        .animation(.smooth(duration: 0.34), value: liveStore.searchError)
    }

    private var shouldShowSearchResultCarousel: Bool {
        !searchResults.isEmpty && !searchIsBusy && searchError == nil
    }

    private var shouldShowRecordingGlow: Bool {
        switch liveStore.status {
        case .failed, .paused:
            previewSearchResult != nil || previewConfirmation != nil
        case .starting, .connecting, .live, .saving, .saved, .searching, .searchComplete, .operationFailed:
            true
        }
    }

    private var searchProgressText: String {
        if let statusText = searchStatusText?.trimmingCharacters(in: .whitespacesAndNewlines), !statusText.isEmpty {
            return statusText
        }

        if let query = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            return "Searching \(query)"
        }

        return "Searching your rewinds"
    }

    private var searchQuery: String? {
        previewSearchResult == nil ? liveStore.searchQuery : "Where is the notebook?"
    }

    private var searchIsBusy: Bool {
        previewSearchResult == nil && liveStore.isSearchBusy
    }

    private var searchStatusText: String? {
        previewSearchResult == nil ? liveStore.searchStatusText : nil
    }

    private var searchResults: [RewindSearchResultCard] {
        if let previewSearchResult {
            return [previewSearchResult]
        }

        return liveStore.searchResults
    }

    private var searchError: String? {
        previewSearchResult == nil ? liveStore.searchError : nil
    }

    private func startWearableExperience() async {
        await liveStore.start()
    }

    private func handleLiveStatusChange(_ status: LiveStatus) {
        // `saving` is emitted from the backend save-request event. Wearable
        // confirmation should be server-backed, but not blocked on the later
        // local frame upload commit path.
        if case let .saving(message) = status {
            showConfirmation(text: message)
        }
    }

    private func showConfirmation(text: String) {
        confirmationDismissTask?.cancel()
        confirmation = WearableMemoryConfirmation(text: text)
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

private struct WearableSearchResultCarouselView: View {
    let query: String?
    let statusText: String?
    let results: [RewindSearchResultCard]

    @State private var activeResultIndex = 0
    @State private var cardOffset = CGSize.zero
    @State private var cardScale = 1.0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let activeResult {
                WearableMemorySearchResultView(
                    query: query,
                    isSearching: false,
                    statusText: statusText,
                    result: activeResult,
                    errorMessage: nil,
                    autoDismissesResult: false
                )
                .scaleEffect(cardScale, anchor: .topTrailing)
                .offset(cardOffset)
            }
        }
        .frame(width: 228, height: 348, alignment: .topTrailing)
        .padding(.leading, Self.motionPadding)
        .padding(.bottom, 18)
        .task(id: resultIdentity) {
            await advanceVisibleResult()
        }
        .onChange(of: resultIdentity) { _, _ in
            activeResultIndex = 0
            cardOffset = .zero
            cardScale = 1
        }
    }

    private var activeResult: RewindSearchResultCard? {
        guard !results.isEmpty else {
            return nil
        }

        return results[min(activeResultIndex, results.count - 1)]
    }

    private var resultIdentity: String {
        results.map(\.id).joined(separator: "-")
    }

    @MainActor
    private func advanceVisibleResult() async {
        activeResultIndex = 0
        cardOffset = .zero
        cardScale = 1

        guard results.count > 1 else {
            return
        }

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(Self.resultAdvanceDelayMilliseconds))
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            withAnimation(.smooth(duration: 0.34)) {
                cardOffset = CGSize(width: -Self.motionPadding, height: 12)
                cardScale = 0.94
            }

            do {
                try await Task.sleep(for: .milliseconds(Self.resultSwapAnimationMilliseconds))
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            activeResultIndex = (activeResultIndex + 1) % results.count
            cardOffset = CGSize(width: 34, height: -8)
            cardScale = 0.96

            withAnimation(.spring(response: 0.58, dampingFraction: 0.82, blendDuration: 0.08)) {
                cardOffset = .zero
                cardScale = 1
            }
        }
    }

    private static let resultAdvanceDelayMilliseconds = 2_900
    private static let resultSwapAnimationMilliseconds = 340
    private static let motionPadding: CGFloat = 28
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

/// Subtle recording affordance shown while the wearable capture surface is active.
private struct WearableRecordingEdgeGlow: View {
    @State private var pulse = false

    var body: some View {
        GeometryReader { proxy in
            let shortestSide = min(proxy.size.width, proxy.size.height)
            let glowWidth = max(7, shortestSide * 0.024)

            ZStack {
                ContainerRelativeShape()
                    .stroke(.red, lineWidth: glowWidth * 1.8)
                    .blur(radius: pulse ? 30 : 18)
                    .opacity(pulse ? 0.74 : 0.52)

                ContainerRelativeShape()
                    .stroke(.red, lineWidth: glowWidth * 0.82)
                    .blur(radius: pulse ? 12 : 7)
                    .opacity(pulse ? 0.68 : 0.42)
            }
            .padding(glowWidth / 2)
            .compositingGroup()
            .onAppear {
                pulse = false
                withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
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

/// Liquid Glass dismissal control for the full-screen wearable capture surface.
private struct WearableSimulationBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(true), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
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

#Preview("Wearable Simulation Back Button") {
    ZStack(alignment: .topLeading) {
        MemoryImageSurface(imageSource: .asset(name: "memory-example-3081"))
            .ignoresSafeArea()

        WearableSimulationBackButton {}
            .padding()
    }
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
