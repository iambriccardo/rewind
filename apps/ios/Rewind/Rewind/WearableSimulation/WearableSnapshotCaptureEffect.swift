//
//  WearableSnapshotCaptureEffect.swift
//  Rewind
//
//  Created by Codex on 6/7/26.
//

import SwiftUI

/// Applies the wearable remembered-frame shader to a SwiftUI-rendered snapshot.
///
/// The shader samples the underlying image, brightens it like a captured frame,
/// then separates source RGB channels through segmented morph offsets so the
/// glow inherits the scene's own colors instead of a fixed palette.
struct WearableSnapshotCaptureEffect: ViewModifier {
    let triggerID: UUID?

    @State private var progress = 1.0

    func body(content: Content) -> some View {
        content
            .modifier(WearableSnapshotCaptureShader(progress: progress))
            .task(id: triggerID) {
                await playIfNeeded()
            }
    }

    @MainActor
    private func playIfNeeded() async {
        guard triggerID != nil else {
            return
        }

        progress = 0

        do {
            try await Task.sleep(for: .milliseconds(35))
        } catch {
            return
        }

        guard !Task.isCancelled else {
            return
        }

        withAnimation(.smooth(duration: Self.duration)) {
            progress = 1
        }
    }

    private static let duration = 2.2
}

private struct WearableSnapshotCaptureShader: ViewModifier, Animatable {
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .visualEffect { view, proxy in
                view.layerEffect(
                    ShaderLibrary.default.wearableSnapshotCapture(
                        .float2(proxy.size),
                        .float(Float(progress))
                    ),
                    maxSampleOffset: CGSize(width: 128, height: 128),
                    isEnabled: progress < 1
                )
            }
    }
}

extension View {
    /// Adds the remembered snapshot shader used by the wearable simulation overlay.
    func wearableSnapshotCaptureEffect(triggerID: UUID?) -> some View {
        modifier(WearableSnapshotCaptureEffect(triggerID: triggerID))
    }
}

private struct WearableSnapshotCaptureEffectPreview: View {
    @State private var triggerID: UUID?

    var body: some View {
        ZStack(alignment: .bottom) {
            Image("memory-example-3089")
                .resizable()
                .scaledToFill()
                .wearableSnapshotCaptureEffect(triggerID: triggerID)
                .ignoresSafeArea()

            Button("Remember") {
                triggerID = UUID()
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }
}

#Preview("Wearable Snapshot Capture Effect") {
    WearableSnapshotCaptureEffectPreview()
        .preferredColorScheme(.dark)
}

private struct WearableSnapshotCaptureProgressPreview: View {
    @State private var progress = 0.35

    var body: some View {
        VStack(spacing: 16) {
            Image("memory-example-3089")
                .resizable()
                .scaledToFill()
                .frame(width: 260, height: 390)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .modifier(WearableSnapshotCaptureShader(progress: progress))

            Slider(value: $progress, in: 0...1)
                .padding(.horizontal)
        }
        .padding()
        .background(.black)
    }
}

#Preview("Wearable Snapshot Capture Progress") {
    WearableSnapshotCaptureProgressPreview()
        .preferredColorScheme(.dark)
}
