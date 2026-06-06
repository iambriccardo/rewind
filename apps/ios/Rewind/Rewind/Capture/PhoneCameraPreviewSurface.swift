//
//  PhoneCameraPreviewSurface.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// Full-bleed camera preview used by the live Rewind surface.
struct PhoneCameraPreviewSurface: View {
    let session: AVCaptureSession
    let saveWaveID: UUID?
    @State private var saveWaveProgress: Double = 0

    init(session: AVCaptureSession, saveWaveID: UUID? = nil) {
        self.session = session
        self.saveWaveID = saveWaveID
    }

    var body: some View {
        GeometryReader { proxy in
            let cornerRadius = min(proxy.size.width, proxy.size.height) * 0.13

            PhoneCameraPreview(session: session)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    CameraSaveWaveOverlay(progress: saveWaveProgress)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
                .onChange(of: saveWaveID) { _, _ in
                    saveWaveProgress = 0
                    withAnimation(.smooth(duration: 1.1)) {
                        saveWaveProgress = 1
                    } completion: {
                        withAnimation(.smooth(duration: 0.35)) {
                            saveWaveProgress = 0
                        }
                    }
                }
        }
    }
}

private struct CameraSaveWaveOverlay: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let activeProgress = max(0, min(1, progress))

            Canvas { context, canvasSize in
                guard activeProgress > 0 else {
                    return
                }

                let waveCenterX = canvasSize.width * CGFloat(activeProgress)
                let baseLineWidth = max(canvasSize.width, canvasSize.height) * 0.018
                for index in 0..<5 {
                    let offset = CGFloat(index - 2) * max(16, canvasSize.width * 0.045)
                    let opacity = max(0, 0.22 - Double(abs(index - 2)) * 0.035) * (1 - abs(activeProgress - 0.55) * 0.55)
                    var path = Path()
                    path.move(to: CGPoint(x: waveCenterX + offset, y: 0))

                    let segments = 12
                    for segment in 0...segments {
                        let y = canvasSize.height * CGFloat(segment) / CGFloat(segments)
                        let phase = y / max(canvasSize.height, 1) * .pi * 3.4
                        let amplitude = max(8, canvasSize.width * 0.022)
                        let x = waveCenterX + offset + sin(phase + CGFloat(activeProgress) * .pi * 2) * amplitude
                        path.addLine(to: CGPoint(x: x, y: y))
                    }

                    context.stroke(
                        path,
                        with: .color(.white.opacity(opacity)),
                        style: StrokeStyle(lineWidth: baseLineWidth * CGFloat(1 + index) / 4, lineCap: .round)
                    )
                }

                let glowRect = CGRect(
                    x: waveCenterX - size.width * 0.18,
                    y: 0,
                    width: size.width * 0.36,
                    height: size.height
                )
                context.fill(
                    Path(glowRect),
                    with: .linearGradient(
                        Gradient(colors: [
                            .white.opacity(0),
                            .white.opacity(0.10 * activeProgress),
                            .white.opacity(0)
                        ]),
                        startPoint: CGPoint(x: glowRect.minX, y: 0),
                        endPoint: CGPoint(x: glowRect.maxX, y: 0)
                    )
                )
            }
            .allowsHitTesting(false)
        }
    }
}

struct PhoneCameraPreview: UIViewRepresentable {
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

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
#endif
