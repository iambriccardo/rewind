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
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
                .frame(width: 20, height: 20)

            Text(item.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.trailing, 4)
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.vertical, 11)
        .background(.black.opacity(0.12), in: Capsule())
        .glassEffect(.regular.tint(.green.opacity(0.14)).interactive(false), in: Capsule())
        .shadow(color: .green.opacity(0.14), radius: 18, y: 8)
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
