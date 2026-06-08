//
//  WearableMemorySearchResultView.swift
//  Rewind
//
//  Created by Codex on 6/7/26.
//

import Foundation
import SwiftUI

/// Top-right wearable search component for live memory retrieval.
///
/// Result cards dismiss themselves after a short confirmation window. The
/// optional auto-dismiss override exists so previews can stay visible while the
/// wearable UI is being tuned.
struct WearableMemorySearchResultView: View {
    let query: String?
    let isSearching: Bool
    let statusText: String?
    let result: RewindSearchResultCard?
    let errorMessage: String?
    let autoDismissesResult: Bool

    @State private var isVisible = false

    init(
        query: String?,
        isSearching: Bool,
        statusText: String? = nil,
        result: RewindSearchResultCard?,
        errorMessage: String?,
        autoDismissesResult: Bool = true
    ) {
        self.query = query
        self.isSearching = isSearching
        self.statusText = statusText
        self.result = result
        self.errorMessage = errorMessage
        self.autoDismissesResult = autoDismissesResult
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            imageCard

            if let result, !isSearching, errorMessage == nil {
                Text(result.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
            }
        }
        .frame(width: 172, alignment: .leading)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.9, anchor: .topTrailing)
        .offset(x: isVisible ? 0 : 10, y: isVisible ? 0 : -6)
        .task(id: presentationID) {
            await animatePresentationLifecycle()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    @MainActor
    private func animatePresentationLifecycle() async {
        isVisible = false

        await Task.yield()
        guard !Task.isCancelled else {
            return
        }

        withAnimation(.smooth(duration: 0.28)) {
            isVisible = true
        }

        guard autoDismissesResult, shouldAutoDismiss else {
            return
        }

        do {
            try await Task.sleep(for: .seconds(3))
        } catch {
            return
        }

        guard !Task.isCancelled else {
            return
        }

        withAnimation(.smooth(duration: 0.24)) {
            isVisible = false
        }
    }

    private var imageCard: some View {
        ZStack {
            cardBackground
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .glassEffect(.clear.interactive(false), in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var cardBackground: some View {
        if let result, !result.frameURLs.isEmpty {
            LoopingSearchResultMemoryCard(frameURLs: result.frameURLs, cornerRadius: Self.cornerRadius)
        } else if result != nil, !isSearching, errorMessage == nil {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.white.opacity(0.10))
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                }
        } else {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.black.opacity(0.34))
                .overlay {
                    if isSearching {
                        VStack(spacing: 12) {
                            SearchPulseGlyph()

                            if let searchProgressText {
                                Text(searchProgressText)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(3)
                                    .minimumScaleFactor(0.78)
                                    .padding(.horizontal, 14)
                            }
                        }
                    } else if errorMessage != nil {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "minus")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
        }
    }

    private var presentationID: String {
        [
            isSearching ? "searching" : "idle",
            statusText ?? "no-status",
            result?.id ?? "no-result",
            errorMessage ?? "no-error"
        ].joined(separator: "-")
    }

    private var shouldAutoDismiss: Bool {
        result != nil && !isSearching && errorMessage == nil
    }

    private var searchProgressText: String? {
        if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            return "Searching \"\(query)\""
        }

        if let statusText = statusText?.trimmingCharacters(in: .whitespacesAndNewlines), !statusText.isEmpty {
            return statusText
        }

        return nil
    }

    private var accessibilitySummary: String {
        if isSearching {
            return statusText ?? query.map { "Finding memory for \($0)" } ?? "Finding memory"
        }

        if let result {
            return "Best match, \(result.title)"
        }

        if let errorMessage {
            return "Search issue, \(errorMessage)"
        }

        return "No memory match found"
    }

    private static let cornerRadius: CGFloat = 28
}

private struct SearchPulseGlyph: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(isPulsing ? 0.08 : 0.30), lineWidth: 8)
                .frame(width: isPulsing ? 96 : 72, height: isPulsing ? 96 : 72)

            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 96, height: 96)
        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isPulsing)
        .onAppear {
            isPulsing = true
        }
    }
}

#Preview("Wearable Search Result") {
    ZStack(alignment: .topTrailing) {
        MemoryImageSurface(imageSource: .asset(name: "memory-example-3081"))
            .ignoresSafeArea()

        WearableMemorySearchResultView(
            query: "Where did I put the notebook?",
            isSearching: false,
            result: WearableSearchResultPreviewData.result,
            errorMessage: nil,
            autoDismissesResult: false
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Wearable Search Result Auto Dismiss") {
    ZStack(alignment: .topTrailing) {
        MemoryImageSurface(imageSource: .asset(name: "memory-example-3081"))
            .ignoresSafeArea()

        WearableMemorySearchResultView(
            query: "Where did I put the notebook?",
            isSearching: false,
            result: WearableSearchResultPreviewData.result,
            errorMessage: nil
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Wearable Search Progress") {
    ZStack(alignment: .topTrailing) {
        MemoryImageSurface(imageSource: .asset(name: "memory-example-3109"))
            .ignoresSafeArea()

        WearableMemorySearchResultView(
            query: "blue adapter",
            isSearching: true,
            statusText: "Searching your rewinds for the blue adapter.",
            result: nil,
            errorMessage: nil
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Wearable Search Empty") {
    ZStack(alignment: .topTrailing) {
        MemoryImageSurface(imageSource: .asset(name: "memory-example-3027"))
            .ignoresSafeArea()

        WearableMemorySearchResultView(
            query: "red notebook",
            isSearching: false,
            result: nil,
            errorMessage: nil
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Wearable Search Error") {
    ZStack(alignment: .topTrailing) {
        MemoryImageSurface(imageSource: .asset(name: "memory-example-3031"))
            .ignoresSafeArea()

        WearableMemorySearchResultView(
            query: "desk",
            isSearching: false,
            result: nil,
            errorMessage: "Search unavailable"
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Wearable Search Without Frames") {
    ZStack(alignment: .topTrailing) {
        MemoryImageSurface(imageSource: .asset(name: "memory-example-3117"))
            .ignoresSafeArea()

        WearableMemorySearchResultView(
            query: "notebook",
            isSearching: false,
            result: WearableSearchResultPreviewData.resultWithoutFrames,
            errorMessage: nil,
            autoDismissesResult: false
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}

private enum WearableSearchResultPreviewData {
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

    static let resultWithoutFrames = RewindSearchResultCard(
        id: "preview-result-without-frames",
        title: "Notebook on the standing desk",
        description: "The notebook was beside the keyboard near the monitor.",
        entities: ["notebook"],
        locationHint: "standing desk",
        frameURLs: [],
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
