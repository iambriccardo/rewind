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
/// The edge shader is always applied as a pure render pass so its visual shape
/// can be tuned independently from scrubber interaction state.
struct MemoryImageSurface: View {
    let imageSource: MemoryImageSource

    init(imageSource: MemoryImageSource) {
        self.imageSource = imageSource
    }

    init(imageName: String) {
        self.imageSource = .asset(name: imageName)
    }

    var body: some View {
        GeometryReader { proxy in
            MemoryImage(source: imageSource)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .memoryWindowEffect(
                    edgeFraction: 0.13
                )
        }
    }
}

private struct MemoryWindowEffect: ViewModifier {
    let edgeFraction: CGFloat

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let fallbackRadius = min(proxy.size.width, proxy.size.height) * edgeFraction

            ZStack(alignment: .center) {
                content
            }
            .compositingGroup()
            .memoryTransitionShader(
                progress: 0.62,
                direction: 1,
                cornerRadius: fallbackRadius,
                edgeWidth: min(proxy.size.width, proxy.size.height) * 0.30
            )
            .clipShape(RoundedRectangle(cornerRadius: fallbackRadius, style: .continuous))
        }
    }
}

private extension View {
    func memoryWindowEffect(
        edgeFraction: CGFloat
    ) -> some View {
        modifier(MemoryWindowEffect(
            edgeFraction: edgeFraction
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
                maxSampleOffset: CGSize(width: 160, height: 160),
                isEnabled: true
            )
        }
    }
}

private struct MemoryImageSurfacePreview: View {
    private let imageNames = [
        "memory-example-3027",
        "memory-example-3028",
        "memory-example-3031",
        "memory-example-3081",
        "memory-example-3089",
        "memory-example-3109",
        "memory-example-3117",
        "memory-example-3134"
    ]

    @State private var selectedImageName = "memory-example-3027"

    var body: some View {
        ZStack(alignment: .bottom) {
            MemoryImageSurface(imageSource: .asset(name: selectedImageName))
                .ignoresSafeArea()

            Picker("Image", selection: $selectedImageName) {
                ForEach(imageNames, id: \.self) { imageName in
                    Text(imageName.replacingOccurrences(of: "memory-example-", with: ""))
                        .tag(imageName)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding()
        }
    }
}

#Preview("Memory Surface") {
    MemoryImageSurfacePreview()
}
