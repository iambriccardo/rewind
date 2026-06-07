//
//  CaptureRememberedBanner.swift
//  Rewind
//
//  Created by Codex on 6/7/26.
//

import SwiftUI

struct CaptureRememberedBannerItem: Identifiable, Equatable {
    let id = UUID()
    let title: String
}

struct CaptureRememberedBannerStack: View {
    let banners: [CaptureRememberedBannerItem]

    var body: some View {
        GeometryReader { proxy in
            GlassEffectContainer(spacing: 12) {
                HStack {
                    VStack(spacing: 8) {
                        ForEach(banners) { banner in
                            CaptureRememberedBanner(item: banner)
                                .padding(.top, banner.id == banners.first?.id ? proxy.safeAreaInsets.top : 0)
                                .transition(
                                    .move(edge: .top)
                                        .combined(with: .scale(scale: 0.6, anchor: .top))
                                        .combined(with: .opacity)
                                )
                        }

                        Spacer()
                    }
                }
                .padding(.horizontal, 32)
            }
            .ignoresSafeArea()
            .frame(maxWidth: .infinity)
        }
    }
}

private struct CaptureRememberedBanner: View {
    let item: CaptureRememberedBannerItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)

            Text(item.title)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular.interactive(false), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

#Preview("Remembered Banner Stack") {
    ZStack {
        Color.black.ignoresSafeArea()

        CaptureRememberedBannerStack(banners: [
            CaptureRememberedBannerItem(title: "Remembered"),
            CaptureRememberedBannerItem(title: "Remembered")
        ])
    }
}
