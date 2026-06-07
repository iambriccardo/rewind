//
//  MemoryImage.swift
//  Rewind
//
//  Created by Florian Schulte on 6/6/26.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Displays a full-bleed memory background from a cached file or preview asset.
///
/// Runtime capture uses file-backed HEIC images written by `CaptureFrameCache`.
/// Asset names remain available for deterministic previews without leaking mock
/// images back into the Today timeline.
struct MemoryImage: View {
    let source: MemoryImageSource

    init(source: MemoryImageSource) {
        self.source = source
    }

    init(imageName: String) {
        self.source = .asset(name: imageName)
    }

    /// Clears decoded file-backed images after the on-device frame cache is deleted.
    @MainActor
    static func clearFileCache() {
#if canImport(UIKit)
        MemoryImageFileCache.removeAll()
#endif
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                content
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch source {
        case let .asset(name):
            if MemoryImageAsset.exists(named: name) {
                Image(name)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                missingImagePlaceholder(title: name)
            }
        case let .file(url):
#if canImport(UIKit)
            if let image = MemoryImageFileCache.image(for: url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                missingImagePlaceholder(title: url.lastPathComponent)
            }
#elseif canImport(AppKit)
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                missingImagePlaceholder(title: url.lastPathComponent)
            }
#else
            missingImagePlaceholder(title: url.lastPathComponent)
#endif
        }
    }

    private func missingImagePlaceholder(title: String) -> some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)

            VStack(spacing: 10) {
                Image(systemName: "photo")
                    .font(.system(size: 34, weight: .medium))

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.secondary)
            .padding()
        }
    }
}

/// Source for a memory image surface.
enum MemoryImageSource: Hashable, Sendable {
    case asset(name: String)
    case file(url: URL)
}

private enum MemoryImageAsset {
    static func exists(named imageName: String) -> Bool {
#if canImport(UIKit)
        UIImage(named: imageName) != nil
#elseif canImport(AppKit)
        NSImage(named: NSImage.Name(imageName)) != nil
#else
        false
#endif
    }
}

#if canImport(UIKit)
@MainActor
private enum MemoryImageFileCache {
    private static let cache = NSCache<NSURL, UIImage>()

    static func image(for url: URL) -> UIImage? {
        let key = url as NSURL
        if let cachedImage = cache.object(forKey: key) {
            return cachedImage
        }

        guard let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }

        cache.setObject(image, forKey: key)
        return image
    }

    static func removeAll() {
        cache.removeAllObjects()
    }
}
#endif

private struct MemoryImagePreview: View {
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

#Preview("Memory Image") {
    MemoryImagePreview()
}
