//
//  LoopingSearchResultMemoryCard.swift
//  Rewind
//
//  Created by Codex on 6/7/26.
//

import Foundation
import SwiftUI

/// Replays the cached frame sequence for a search result.
///
/// Search results and the wearable simulation both use this component so
/// memory retrieval has one image treatment across Rewind surfaces.
struct LoopingSearchResultMemoryCard: View {
    let frameURLs: [URL]
    let cornerRadius: CGFloat
    @State private var selectedFrameIndex = 0

    var body: some View {
        ZStack {
            if let currentFrameURL {
                MemoryImage(source: .file(url: currentFrameURL))
            }
        }
        .scaleEffect(1.045)
        .compositingGroup()
        .memoryTransitionShader(
            progress: Self.shaderProgress,
            direction: 1,
            cornerRadius: cornerRadius,
            edgeWidth: cornerRadius * 1.8
        )
        .clipped()
        .task(id: frameURLs) {
            await loopFrames()
        }
        .onChange(of: frameURLs) { _, _ in
            selectedFrameIndex = 0
        }
    }

    private var currentFrameURL: URL? {
        guard !frameURLs.isEmpty else {
            return nil
        }

        return frameURLs[min(selectedFrameIndex, frameURLs.count - 1)]
    }

    @MainActor
    private func loopFrames() async {
        guard frameURLs.count > 1 else {
            selectedFrameIndex = 0
            return
        }

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(Self.frameIntervalMilliseconds))
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            selectedFrameIndex = (selectedFrameIndex + 1) % frameURLs.count
        }
    }

    private static let frameIntervalMilliseconds = 143
    private static let shaderProgress = 0.62
}

#Preview("Looping Search Result Memory Card") {
    ZStack {
        Color.black.ignoresSafeArea()

        LoopingSearchResultMemoryCard(
            frameURLs: LoopingSearchResultMemoryCardPreviewData.frameURLs,
            cornerRadius: 32
        )
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .frame(width: 240)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }
}

#Preview("Looping Search Result Memory Card Empty") {
    ZStack {
        Color.black.ignoresSafeArea()

        LoopingSearchResultMemoryCard(
            frameURLs: [],
            cornerRadius: 32
        )
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .frame(width: 240)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }
}

private enum LoopingSearchResultMemoryCardPreviewData {
    static let frameURLs = [
        assetFrameURL(named: "memory-example-3081"),
        assetFrameURL(named: "memory-example-3089"),
        assetFrameURL(named: "memory-example-3109")
    ]

    private static func assetFrameURL(named imageName: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Assets.xcassets")
            .appendingPathComponent("\(imageName).imageset")
            .appendingPathComponent("\(imageName).jpeg")
    }
}
