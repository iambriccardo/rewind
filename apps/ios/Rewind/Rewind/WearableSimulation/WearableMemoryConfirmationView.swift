//
//  WearableMemoryConfirmationView.swift
//  Rewind
//
//  Created by Codex on 6/7/26.
//

import SwiftUI

/// Ephemeral confirmation shown when the live protocol commits a memory.
struct WearableMemoryConfirmation: Identifiable, Equatable {
    let id = UUID()
}

/// Top-right wearable confirmation component for saved memories.
struct WearableMemoryConfirmationView: View {
    let confirmation: WearableMemoryConfirmation
    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)

            Text("Remembered")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.24), in: Capsule())
        .glassEffect(.regular.interactive(false), in: Capsule())
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.86, anchor: .topTrailing)
        .offset(y: isVisible ? 0 : -8)
        .onAppear {
            withAnimation(.smooth(duration: 0.24)) {
                isVisible = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Remembered")
    }
}

#Preview("Wearable Confirmation") {
    ZStack(alignment: .topTrailing) {
        MemoryImageSurface(imageSource: .asset(name: "memory-example-3027"))
            .ignoresSafeArea()

        WearableMemoryConfirmationView(
            confirmation: WearableMemoryConfirmation()
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}
