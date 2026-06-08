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
    let text: String

    init(text: String = "Remembering") {
        self.text = text
    }
}

/// Bottom-centered wearable confirmation component for saved memories.
struct WearableMemoryConfirmationView: View {
    let confirmation: WearableMemoryConfirmation

    var body: some View {
        WearableStatusTextChip(text: confirmation.text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(confirmation.text)
    }
}

/// Text-only wearable status chip used for transient live feedback.
struct WearableStatusTextChip: View {
    let text: String

    @State private var isPresented = false
    @State private var shimmerOffset: CGFloat = -0.9

    var body: some View {
        Text(text)
            .font(.system(.headline, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .background {
                Capsule()
                    .fill(.black.opacity(0.22))
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    }
            }
            .glassEffect(.regular.interactive(false), in: Capsule())
            .overlay {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.22), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .offset(x: shimmerOffset * 260)
                    .blendMode(.screen)
                    .mask(Capsule())
            }
            .shadow(color: .white.opacity(0.16), radius: 24, y: 10)
            .frame(maxWidth: 340)
            .opacity(isPresented ? 1 : 0)
            .blur(radius: isPresented ? 0 : 8)
            .scaleEffect(isPresented ? 1 : 0.86, anchor: .bottom)
            .offset(y: isPresented ? 0 : 18)
            .onAppear {
                withAnimation(.smooth(duration: 0.34)) {
                    isPresented = true
                }
                withAnimation(.easeInOut(duration: 1.35).delay(0.08)) {
                    shimmerOffset = 0.9
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(text)
    }
}

extension AnyTransition {
    static var wearableBottomText: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom)
                .combined(with: .scale(scale: 0.86, anchor: .bottom))
                .combined(with: .opacity),
            removal: .scale(scale: 0.94, anchor: .bottom)
                .combined(with: .opacity)
        )
    }
}

#Preview("Wearable Confirmation") {
    ZStack(alignment: .bottom) {
        MemoryImageSurface(imageSource: .asset(name: "memory-example-3027"))
            .ignoresSafeArea()

        WearableMemoryConfirmationView(
            confirmation: WearableMemoryConfirmation()
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Wearable Status Text") {
    ZStack(alignment: .bottom) {
        MemoryImageSurface(imageSource: .asset(name: "memory-example-3081"))
            .ignoresSafeArea()

        WearableStatusTextChip(text: "Searching your rewinds for the blue notebook")
            .padding()
    }
    .preferredColorScheme(.dark)
}
