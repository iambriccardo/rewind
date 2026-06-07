//
//  WearableSnapshotCaptureOverlay.swift
//  Rewind
//
//  Created by Codex on 6/7/26.
//

import SwiftUI

/// Shows a shader-treated still frame above the live camera when a memory is saved.
///
/// Applying SwiftUI layer shaders directly to `AVCaptureVideoPreviewLayer` can
/// hit iOS' unsupported rendering path. This overlay uses the latest cached
/// SwiftUI-rendered frame instead, which gives a screenshot-like capture moment
/// while keeping the live camera preview stable underneath.
struct WearableSnapshotCaptureOverlay: View {
    let triggerID: UUID?
    let frame: CachedCaptureFrame?
    let previewImageName: String?

    @State private var activeTriggerID: UUID?
    @State private var imageSource: MemoryImageSource?
    @State private var isPresented = false

    init(
        triggerID: UUID?,
        frame: CachedCaptureFrame?,
        previewImageName: String? = nil
    ) {
        self.triggerID = triggerID
        self.frame = frame
        self.previewImageName = previewImageName
    }

    var body: some View {
        ZStack {
            if isPresented, let imageSource {
                MemoryImage(source: imageSource)
                    .wearableSnapshotCaptureEffect(triggerID: activeTriggerID)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.18), value: isPresented)
        .task(id: triggerID) {
            await presentIfNeeded()
        }
    }

    @MainActor
    private func presentIfNeeded() async {
        guard let triggerID, let nextImageSource else {
            return
        }

        imageSource = nextImageSource
        activeTriggerID = triggerID
        isPresented = true

        do {
            try await Task.sleep(for: .seconds(Self.visibleDuration))
        } catch {
            return
        }

        guard !Task.isCancelled else {
            return
        }

        isPresented = false
    }

    private var nextImageSource: MemoryImageSource? {
        if let frame {
            return .file(url: frame.fileURL)
        }

        if let previewImageName {
            return .asset(name: previewImageName)
        }

        return nil
    }

    private static let visibleDuration: TimeInterval = 2.55
}

private struct WearableSnapshotCaptureOverlayPreview: View {
    @State private var triggerID: UUID?

    var body: some View {
        ZStack(alignment: .bottom) {
            Image("memory-example-3089")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            WearableSnapshotCaptureOverlay(
                triggerID: triggerID,
                frame: nil,
                previewImageName: "memory-example-3089"
            )
            .ignoresSafeArea()

            Button("Remember") {
                triggerID = UUID()
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }
}

#Preview("Wearable Snapshot Capture Overlay") {
    WearableSnapshotCaptureOverlayPreview()
        .preferredColorScheme(.dark)
}
