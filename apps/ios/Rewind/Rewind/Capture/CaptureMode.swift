//
//  CaptureMode.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

import SwiftUI

#if os(iOS)
import AVFoundation
import UIKit

/// Temporary phone-backed capture mode for validating stream shape before glasses hardware arrives.
struct CaptureMode: View {
    @State private var controller = PhoneCaptureController()

    var body: some View {
        ZStack {
            PhoneCameraPreview(session: controller.previewSession)
                .ignoresSafeArea()

            VStack {
                Spacer()

                CaptureStatusPanel(controller: controller)
                    .padding()
            }
        }
        .navigationTitle("Capture Mode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            if controller.state == .idle {
                await controller.start()
            }
        }
        .onDisappear {
            Task {
                await controller.stop()
            }
        }
    }
}

private struct CaptureStatusPanel: View {
    let controller: PhoneCaptureController

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label(controller.state.title, systemImage: controller.isRunning ? "record.circle" : "pause.circle")
                    .font(.headline)

                Spacer()

                Text("\(PhoneCaptureController.captureFrameRate) FPS")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                CaptureMetric(title: "Capture", value: controller.capturedVideoFrameCount)
                CaptureMetric(title: "Stream", value: controller.streamedVideoFrameCount)
                CaptureMetric(title: "Cache", value: controller.cachedVideoFrameCount)
                CaptureMetric(title: "Audio", value: controller.audioChunkCount)
            }

            if case let .failed(message) = controller.state {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button {
                    Task {
                        await controller.stop()
                    }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!controller.isRunning)

                Button {
                    Task {
                        await controller.start()
                    }
                } label: {
                    Label("Start", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.state == .requestingAccess || controller.state == .stopping || controller.isRunning)
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CaptureMetric: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value, format: .number)
                .font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PhoneCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
#else
struct CaptureMode: View {
    var body: some View {
        ContentUnavailableView("Capture Mode", systemImage: "camera.viewfinder")
            .navigationTitle("Capture Mode")
    }
}
#endif

#Preview {
    NavigationStack {
        CaptureMode()
    }
}
