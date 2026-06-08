//
//  SearchResultFocusOverlay.swift
//  Rewind
//
//  Created by Codex on 6/7/26.
//

import SwiftUI

/// Full-screen focus viewer for a retrieved memory result.
///
/// The overlay renders a single frame at a time and scrubs by index, which keeps
/// long result clips responsive without layering every cached image.
struct SearchResultFocusOverlay: View {
    let result: RewindSearchResultCard
    let namespace: Namespace.ID
    let matchedGeometryID: String
    let onDismiss: () -> Void

    @State private var selectedFrameIndex = 0
    @State private var dragStartFrameIndex = 0
    @State private var isDragging = false
    @State private var entranceProgress = 0.0
    @State private var dismissOffset = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            let cardSize = focusedCardSize(in: proxy.size)

            ZStack {
                backdrop
                    .opacity(backdropOpacity)
                    .ignoresSafeArea()
                    .onTapGesture(perform: dismiss)

                VStack(spacing: 18) {
                    focusedCard(size: cardSize)

                    focusMetadata
                        .opacity(metadataOpacity)
                        .offset(y: metadataOffset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
                .offset(dismissOffset)
                .scaleEffect(cardScale)
                .animation(.spring(response: 0.24, dampingFraction: 0.68), value: selectedFrameIndex)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(dismissGesture)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .task(id: result.id) {
            resetPlayback()
        }
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.66)) {
                entranceProgress = 1
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(result.title)
        .accessibilityAddTraits(.isModal)
    }

    private var backdrop: some View {
        ZStack {
            Color.black

            if let currentFrameURL {
                MemoryImage(source: .file(url: currentFrameURL))
                    .scaleEffect(1.16)
                    .blur(radius: 34)
                    .saturation(1.08)
                    .opacity(0.32)
            }

            RadialGradient(
                colors: [
                    .white.opacity(0.15),
                    .black.opacity(0.25),
                    .black.opacity(0.78)
                ],
                center: .center,
                startRadius: 60,
                endRadius: 560
            )
        }
    }

    private func focusedCard(size: CGSize) -> some View {
        ZStack {
            currentFrame
                .clipShape(RoundedRectangle(cornerRadius: Self.outerCornerRadius, style: .continuous))
                .overlay {
                    subtleGlassSheen
                }

            frameProgressRail
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .background(.black, in: RoundedRectangle(cornerRadius: Self.outerCornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Self.outerCornerRadius, style: .continuous))
        .matchedGeometryEffect(id: matchedGeometryID, in: namespace, isSource: false)
        .shadow(color: .black.opacity(0.62), radius: 38, x: 0, y: 24)
        .shadow(color: .white.opacity(isDragging ? 0.18 : 0.08), radius: isDragging ? 34 : 18, x: 0, y: 0)
        .contentShape(RoundedRectangle(cornerRadius: Self.outerCornerRadius, style: .continuous))
        .gesture(scrubGesture)
        .onTapGesture(perform: dismiss)
    }

    @ViewBuilder
    private var currentFrame: some View {
        if let currentFrameURL {
            MemoryImage(source: .file(url: currentFrameURL))
                .scaleEffect(isDragging ? 1.02 : 1.045)
                .compositingGroup()
                .memoryTransitionShader(
                    progress: Self.shaderProgress,
                    direction: 1,
                    cornerRadius: Self.outerCornerRadius,
                    edgeWidth: Self.outerCornerRadius * 1.7
                )
                .clipped()
        } else {
            Rectangle()
                .fill(.white.opacity(0.07))
        }
    }

    private var subtleGlassSheen: some View {
        LinearGradient(
            colors: [
                .white.opacity(0.16),
                .clear,
                .black.opacity(0.22)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .allowsHitTesting(false)
    }

    private var frameProgressRail: some View {
        GeometryReader { proxy in
            let progress = frameProgress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.18))

                Capsule()
                    .fill(.white.opacity(0.72))
                    .frame(width: max(18, proxy.size.width * progress))
            }
        }
        .frame(height: 4)
        .opacity(frameURLs.count > 1 ? 1 : 0)
    }

    private var focusMetadata: some View {
        VStack(spacing: 7) {
            Text(result.title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            if !result.description.isEmpty {
                Text(result.description)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }
        }
        .frame(maxWidth: 340)
        .padding(.horizontal, 18)
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                guard frameURLs.count > 1 else {
                    return
                }

                if !isDragging {
                    dragStartFrameIndex = selectedFrameIndex
                    isDragging = true
                }

                selectedFrameIndex = clampedFrameIndex(dragStartFrameIndex + frameDelta(for: value.translation))
            }
            .onEnded { value in
                if abs(value.translation.height) > Self.dismissDistance, abs(value.translation.height) > abs(value.translation.width) * 1.25 {
                    dismissOffset = value.translation
                    dismiss()
                    return
                }

                dragStartFrameIndex = selectedFrameIndex
                isDragging = false
            }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .global)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) * 1.35 else {
                    return
                }

                dismissOffset = CGSize(width: 0, height: value.translation.height)
            }
            .onEnded { value in
                if abs(value.translation.height) > Self.dismissDistance {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        dismissOffset = .zero
                    }
                }
            }
    }

    private var currentFrameURL: URL? {
        guard !frameURLs.isEmpty else {
            return nil
        }

        return frameURLs[min(selectedFrameIndex, frameURLs.count - 1)]
    }

    private var frameURLs: [URL] {
        result.frameURLs
    }

    private var frameProgress: CGFloat {
        guard frameURLs.count > 1 else {
            return 1
        }

        return CGFloat(selectedFrameIndex) / CGFloat(frameURLs.count - 1)
    }

    private var backdropOpacity: Double {
        let dragFade = min(abs(dismissOffset.height) / 420, 0.35)
        return max(0, entranceProgress - dragFade)
    }

    private var cardScale: CGFloat {
        let dragScale = min(abs(dismissOffset.height) / 1_200, 0.08)
        return CGFloat(0.94 + entranceProgress * 0.06) - dragScale
    }

    private var metadataOpacity: Double {
        max(0, entranceProgress - min(abs(dismissOffset.height) / 260, 0.8))
    }

    private var metadataOffset: CGFloat {
        CGFloat(18 * (1 - entranceProgress)) + abs(dismissOffset.height) * 0.08
    }

    private func focusedCardSize(in containerSize: CGSize) -> CGSize {
        let availableWidth = min(max(containerSize.width - 40, 1), 390)
        let availableHeight = max(containerSize.height - 190, 1)
        let height = min(availableWidth * Self.cardAspectRatio, availableHeight)
        let width = height / Self.cardAspectRatio
        return CGSize(width: width, height: height)
    }

    private func resetPlayback() {
        selectedFrameIndex = 0
        dragStartFrameIndex = 0
        isDragging = false
        dismissOffset = .zero
    }

    private func clampedFrameIndex(_ proposedIndex: Int) -> Int {
        min(max(proposedIndex, 0), max(frameURLs.count - 1, 0))
    }

    private func frameDelta(for translation: CGSize) -> Int {
        let combinedDelta = translation.width - translation.height * 0.55
        return Int((combinedDelta / Self.pointsPerFrame).rounded())
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.76)) {
            entranceProgress = 0
            dismissOffset = CGSize(width: dismissOffset.width, height: dismissOffset.height == 0 ? 18 : dismissOffset.height)
        } completion: {
            onDismiss()
        }
    }

    private static let outerCornerRadius: CGFloat = 38
    private static let cardAspectRatio: CGFloat = 1.46
    private static let pointsPerFrame: CGFloat = 14
    private static let dismissDistance: CGFloat = 140
    private static let shaderProgress = 0.62
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#Preview("Search Result Focus Overlay") {
    SearchResultFocusOverlayPreview()
}

private struct SearchResultFocusOverlayPreview: View {
    @Namespace private var namespace

    var body: some View {
        SearchResultFocusOverlay(
            result: SearchResultFocusOverlayPreviewData.result,
            namespace: namespace,
            matchedGeometryID: "preview-result",
            onDismiss: {}
        )
    }
}

private enum SearchResultFocusOverlayPreviewData {
    static let result = RewindSearchResultCard(
        id: "preview-result",
        title: "Desk beside the notebook",
        description: "A remembered workspace moment with the pen near the laptop.",
        entities: ["desk", "notebook", "pen"],
        locationHint: "Studio",
        frameURLs: [
            assetFrameURL(named: "memory-example-3081"),
            assetFrameURL(named: "memory-example-3089"),
            assetFrameURL(named: "memory-example-3109"),
            assetFrameURL(named: "memory-example-3117")
        ],
        score: 0.91
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
