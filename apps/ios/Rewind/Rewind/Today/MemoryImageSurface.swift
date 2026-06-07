//
//  MemoryImageSurface.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

import SwiftUI

/// Presents a memory image with the soft edge treatment used by the day timeline.
///
/// The surface owns only visual state. Runtime callers provide cached file sources,
/// while previews can still use asset sources. Source changes are rendered
/// immediately so scrubbing through captures does not crossfade between frames.
/// The moving image shader and solid device rim are separate layers so the
/// outside edge can stay pure black while the image below keeps its zoom motion.
struct MemoryImageSurface: View {
    let imageSource: MemoryImageSource
    let saveWaveID: UUID?

    init(imageSource: MemoryImageSource, saveWaveID: UUID? = nil) {
        self.imageSource = imageSource
        self.saveWaveID = saveWaveID
    }

    init(imageName: String, saveWaveID: UUID? = nil) {
        self.imageSource = .asset(name: imageName)
        self.saveWaveID = saveWaveID
    }

    var body: some View {
        GeometryReader { proxy in
            MemoryImage(source: imageSource)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .memoryWindowEffect(edgeFraction: 0.13, saveWaveID: saveWaveID)
        }
    }
}

struct MemoryWindowEffect: ViewModifier {
    let edgeFraction: CGFloat
    let saveWaveID: UUID?
    @State private var saveWaveProgress = 0.62

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let shorterSide = min(proxy.size.width, proxy.size.height)
            let fallbackRadius = shorterSide * edgeFraction
            let rimWidth = max(shorterSide * 0.052, 14)
            let topDeviceInset = max(proxy.safeAreaInsets.top, shorterSide * 0.13)
            let imageTopInset = topDeviceInset + rimWidth * 0.55
            let imageSideInset = rimWidth
            let imageBottomInset = rimWidth
            let imageSize = CGSize(
                width: max(proxy.size.width - imageSideInset * 2, 1),
                height: max(proxy.size.height - imageTopInset - imageBottomInset, 1)
            )
            let imageCornerRadius = max(fallbackRadius - rimWidth * 0.72, 18)

            ZStack(alignment: .center) {
                Color.black

                ZStack {
                    content
                        .frame(width: imageSize.width, height: imageSize.height)
                        .scaleEffect(1.045)
                        .compositingGroup()
                            .memoryTransitionShader(
                                progress: saveWaveProgress,
                                direction: 1,
                                cornerRadius: imageCornerRadius,
                                edgeWidth: shorterSide * 0.15
                            )
                }
                .frame(width: imageSize.width, height: imageSize.height)
                .clipShape(RoundedRectangle(cornerRadius: imageCornerRadius, style: .continuous))
                .position(
                    x: proxy.size.width / 2,
                    y: imageTopInset + imageSize.height / 2
                )

                MemoryWindowDeviceRim(cornerRadius: fallbackRadius, width: rimWidth)
            }
            .clipShape(RoundedRectangle(cornerRadius: fallbackRadius, style: .continuous))
            .onChange(of: saveWaveID) { _, _ in
                saveWaveProgress = 0
                withAnimation(.smooth(duration: 1.15)) {
                    saveWaveProgress = 1
                } completion: {
                    withAnimation(.smooth(duration: 0.5)) {
                        saveWaveProgress = 0.62
                    }
                }
            }
        }
    }
}

private struct MemoryWindowDeviceRim: View {
    let cornerRadius: CGFloat
    let width: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(.black, lineWidth: width)
            .allowsHitTesting(false)
    }
}

extension View {
    func memoryWindowEffect(
        edgeFraction: CGFloat,
        saveWaveID: UUID? = nil
    ) -> some View {
        modifier(MemoryWindowEffect(
            edgeFraction: edgeFraction,
            saveWaveID: saveWaveID
        ))
    }

    func memoryTransitionShader(
        progress: Double,
        direction: Double,
        cornerRadius: CGFloat,
        edgeWidth: CGFloat
    ) -> some View {
        visualEffect { view, proxy in
            view.layerEffect(
                ShaderLibrary.default.memoryTransition(
                    .float2(proxy.size),
                    .float(Float(progress)),
                    .float(Float(direction)),
                    .float(Float(cornerRadius)),
                    .float(Float(edgeWidth))
                ),
                // Matches the shader's longest edge-weighted zoom taps so outward streaks are not clipped.
                maxSampleOffset: CGSize(width: 900, height: 900),
                isEnabled: true
            )
        }
    }
}

private struct MemoryImageSurfacePreviewBoard: View {
    let progress: Double

    private let imageNames = ["memory-example-3027", "memory-example-3089", "memory-example-3117", "memory-example-3134"]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(imageNames, id: \.self) { imageName in
                    MemoryImageSurfacePreviewTile(imageName: imageName, progress: progress)
                }
            }
            .padding(14)
        }
        .background(.black)
    }

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 14),
            GridItem(.flexible(), spacing: 14)
        ]
    }
}

private struct MemoryImageSurfacePreviewTile: View {
    let imageName: String
    let progress: Double

    var body: some View {
        MemoryImage(source: .asset(name: imageName))
            .memoryTransitionPreviewEffect(progress: progress)
            .frame(height: 260)
    }
}

private struct MemoryImageSurfaceTallPreview: View {
    let imageName: String
    let progress: Double

    var body: some View {
        MemoryImage(source: .asset(name: imageName))
            .memoryTransitionPreviewEffect(progress: progress)
            .ignoresSafeArea()
    }
}

private extension View {
    func memoryTransitionPreviewEffect(progress: Double) -> some View {
        GeometryReader { proxy in
            let shorterSide = min(proxy.size.width, proxy.size.height)
            let cornerRadius = shorterSide * 0.13
            let rimWidth = max(shorterSide * 0.052, 14)
            let imageTopInset = shorterSide * 0.13 + rimWidth * 0.55
            let imageSize = CGSize(
                width: max(proxy.size.width - rimWidth * 2, 1),
                height: max(proxy.size.height - imageTopInset - rimWidth, 1)
            )
            let imageCornerRadius = max(cornerRadius - rimWidth * 0.72, 18)

            self
                .modifier(MemoryTransitionPreviewEffect(
                    progress: progress,
                    cornerRadius: cornerRadius,
                    imageCornerRadius: imageCornerRadius,
                    edgeWidth: shorterSide * 0.15,
                    rimWidth: rimWidth,
                    imageTopInset: imageTopInset,
                    imageSize: imageSize,
                    surfaceSize: proxy.size
                ))
        }
    }
}

private struct MemoryTransitionPreviewEffect: ViewModifier {
    let progress: Double
    let cornerRadius: CGFloat
    let imageCornerRadius: CGFloat
    let edgeWidth: CGFloat
    let rimWidth: CGFloat
    let imageTopInset: CGFloat
    let imageSize: CGSize
    let surfaceSize: CGSize

    func body(content: Content) -> some View {
        ZStack {
            Color.black

            ZStack {
                content
                    .frame(width: imageSize.width, height: imageSize.height)
                    .scaleEffect(1.045)
                    .compositingGroup()
                    .memoryTransitionShader(
                        progress: progress,
                        direction: 1,
                        cornerRadius: imageCornerRadius,
                        edgeWidth: edgeWidth
                    )
            }
            .frame(width: imageSize.width, height: imageSize.height)
            .clipShape(RoundedRectangle(cornerRadius: imageCornerRadius, style: .continuous))
            .position(
                x: surfaceSize.width / 2,
                y: imageTopInset + imageSize.height / 2
            )

            MemoryWindowDeviceRim(cornerRadius: cornerRadius, width: rimWidth)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

#Preview("Focus Blur - Resting", traits: .fixedLayout(width: 393, height: 852)) {
    MemoryImageSurfacePreviewBoard(progress: 0.62)
}

#Preview("Focus Blur - Save Wave", traits: .fixedLayout(width: 393, height: 852)) {
    MemoryImageSurfacePreviewBoard(progress: 1)
}

#Preview("Focus Blur - Tall Contrast", traits: .fixedLayout(width: 393, height: 852)) {
    MemoryImageSurfaceTallPreview(imageName: "memory-example-3089", progress: 1)
}
