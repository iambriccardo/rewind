//
//  LiveCapture.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

import SwiftUI

/// Dedicated live recording surface.
///
/// This view owns capture lifecycle independently from `Today`, so browsing old
/// memories cannot interfere with camera setup, preview, or shutdown.
struct LiveCapture: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var liveStore = RewindLiveStore()
    @State private var rememberedBanners: [CaptureRememberedBannerItem] = []

    var body: some View {
        ZStack {
            cameraSurface
                .ignoresSafeArea()

            RecordingEdgeGlow()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            CaptureSaveRipple(saveWaveID: liveStore.saveWaveID)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            CaptureRememberedBannerStack(banners: rememberedBanners)
                .allowsHitTesting(false)
                .zIndex(20)

            if liveStore.isSaving {
                LiveProgressStatusBanner(
                    text: liveStore.saveStatusText,
                    fallbackText: "Remembering this rewind.",
                    systemImage: "sparkles",
                    tint: .green
                )
                .padding(.top, 18)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(30)
            } else if liveStore.isSearchBusy {
                LiveProgressStatusBanner(
                    text: liveStore.searchStatusText,
                    fallbackText: "Searching your rewinds.",
                    systemImage: "magnifyingglass",
                    tint: .white
                )
                .padding(.top, 18)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(30)
            }

            VStack {
                Spacer()

                Button {
                    dismiss()
                } label: {
                    ZStack {
                        Circle()
                            .fill(.red.opacity(0.16))

                        Image(systemName: "stop.fill")
                            .font(.system(size: 31, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 88, height: 88)
                    .overlay {
                        Circle()
                            .stroke(.red.opacity(0.28), lineWidth: 1)
                    }
                    .shadow(color: .red.opacity(0.32), radius: 24, y: 8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.red).interactive(true), in: Circle())
                .accessibilityLabel("Stop recording")
                .padding(.bottom, 24)
            }
        }
        .background(.black)
        .task {
            await liveStore.start()
        }
        .onDisappear {
            Task {
                await liveStore.stop()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                switch phase {
                case .active:
                    await liveStore.start()
                case .inactive, .background:
                    await liveStore.stop()
                @unknown default:
                    break
                }
            }
        }
        .onChange(of: liveStore.status) { _, status in
            if case let .saved(title, _) = status {
                showRememberedBanner(title: title)
            }
        }
        .animation(.smooth(duration: 0.24), value: liveStore.isSearchBusy)
        .animation(.smooth(duration: 0.24), value: liveStore.isSaving)
    }

    @ViewBuilder
    private var cameraSurface: some View {
#if os(iOS)
        switch liveStore.captureController.state {
        case .running:
            PhoneCameraPreview(session: liveStore.captureController.previewSession)
        case .failed:
            ContentUnavailableView("No camera", systemImage: "camera.viewfinder")
                .foregroundStyle(.white)
        case .idle, .requestingAccess, .stopping:
            Rectangle()
                .fill(.black)
        }
#else
        ContentUnavailableView("No camera", systemImage: "camera.viewfinder")
            .foregroundStyle(.white)
#endif
    }

    private func showRememberedBanner(title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let banner = CaptureRememberedBannerItem(title: trimmedTitle.isEmpty ? "Remembered" : "Remembered \(trimmedTitle)")

        withAnimation(.smooth(duration: 0.24)) {
            rememberedBanners.insert(banner, at: 0)
        }

        Task {
            try? await Task.sleep(for: .seconds(2.4))

            await MainActor.run {
                withAnimation(.smooth(duration: 0.22)) {
                    rememberedBanners.removeAll { $0.id == banner.id }
                }
            }
        }
    }
}

private struct LiveProgressStatusBanner: View {
    let text: String?
    let fallbackText: String
    let systemImage: String
    let tint: Color
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(isPulsing ? 0.12 : 0.34), lineWidth: 7)
                    .frame(width: isPulsing ? 46 : 32, height: isPulsing ? 46 : 32)

                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 48, height: 48)
            .animation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true), value: isPulsing)

            Text(text ?? fallbackText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 420)
        .background(.black.opacity(0.18), in: Capsule())
        .glassEffect(.regular.tint(tint.opacity(0.18)).interactive(false), in: Capsule())
        .shadow(color: tint.opacity(0.18), radius: 22, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text ?? fallbackText)
        .onAppear {
            isPulsing = true
        }
    }
}

private struct RecordingEdgeGlow: View {
    @State private var pulse = false

    var body: some View {
        GeometryReader { proxy in
            let shortestSide = min(proxy.size.width, proxy.size.height)
            let glowWidth = max(9, shortestSide * 0.03)

            ZStack {
                ContainerRelativeShape()
                    .stroke(.red, lineWidth: glowWidth * 2.1)
                    .blur(radius: pulse ? 38 : 24)
                    .opacity(pulse ? 1 : 0.88)

                ContainerRelativeShape()
                    .stroke(.red, lineWidth: glowWidth * 1.15)
                    .blur(radius: pulse ? 18 : 10)
                    .opacity(pulse ? 1 : 0.78)

                ContainerRelativeShape()
                    .stroke(.red, lineWidth: glowWidth * 0.52)
                    .blur(radius: pulse ? 8 : 5)
                    .opacity(pulse ? 0.96 : 0.72)
            }
            .padding(glowWidth / 2)
            .compositingGroup()
            .onAppear {
                pulse = false
                withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
    }
}

private struct CaptureSaveRipple: View {
    let saveWaveID: UUID
    @State private var progress = 0.0

    var body: some View {
        Canvas { context, size in
            guard progress > 0 else {
                return
            }

            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let maximumRadius = hypot(size.width, size.height)
            let baseRadius = maximumRadius * CGFloat(progress)
            let fade = max(0, 1 - progress)

            for index in 0..<4 {
                let radius = baseRadius - CGFloat(index) * 42
                guard radius > 0 else {
                    continue
                }

                let opacity = fade * (0.22 - Double(index) * 0.035)
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )

                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(.white.opacity(opacity)),
                    lineWidth: max(2, maximumRadius * 0.014)
                )
            }
        }
        .background(.white.opacity(progress > 0 ? max(0, 0.08 * (1 - progress)) : 0))
        .onChange(of: saveWaveID) { _, _ in
            progress = 0
            withAnimation(.smooth(duration: 1.05)) {
                progress = 1
            } completion: {
                progress = 0
            }
        }
    }
}

#Preview("Live Capture") {
    LiveCapture()
}
