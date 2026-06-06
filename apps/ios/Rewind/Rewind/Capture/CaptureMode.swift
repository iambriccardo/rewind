//
//  CaptureMode.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

import SwiftUI

#if os(iOS)

/// Debug-only view for inspecting the live phone capture surface.
///
/// The production surface starts automatically from `Today`; this screen intentionally
/// avoids manual controls so it behaves like the real app entry point.
struct CaptureMode: View {
    @State private var controller = PhoneCaptureController()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PhoneCameraPreviewSurface(session: controller.previewSession)
                .ignoresSafeArea()

            CaptureStatusBadge(controller: controller)
                .padding()
        }
        .navigationTitle("Live capture")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await controller.start()
        }
    }
}

private struct CaptureStatusBadge: View {
    let controller: PhoneCaptureController

    var body: some View {
        Label(controller.state.title, systemImage: controller.isRunning ? "waveform" : "antenna.radiowaves.left.and.right")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
    }
}
#else
struct CaptureMode: View {
    var body: some View {
        ContentUnavailableView("Capture mode", systemImage: "camera.viewfinder")
            .navigationTitle("Capture mode")
    }
}
#endif

#Preview {
    NavigationStack {
        CaptureMode()
    }
}
