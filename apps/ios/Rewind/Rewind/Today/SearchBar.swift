//
//  SearchBar.swift
//  Rewind
//
//  Created by Florian Schulte on 6/6/26.
//

import SwiftUI

/// A bottom search control for entering the dedicated search experience.
struct SearchBar: View {
    @Binding private var searchText: String
    @Binding private var requestFocus: Bool
    @Binding private var isFocused: Bool
    private let isBusy: Bool
    private let onSubmit: () -> Void

    init(
        searchText: Binding<String>,
        requestFocus: Binding<Bool>,
        isFocused: Binding<Bool>,
        isBusy: Bool = false,
        onSubmit: @escaping () -> Void = {}
    ) {
        self._searchText = searchText
        self._requestFocus = requestFocus
        self._isFocused = isFocused
        self.isBusy = isBusy
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")

#if os(iOS)
                ImmediateSearchTextField(
                    "Search",
                    text: $searchText,
                    requestFocus: $requestFocus,
                    isFocused: $isFocused,
                    isEnabled: true,
                    onSubmit: onSubmit
                )
                .frame(height: 24)
#else
                TextField("Search", text: $searchText)
                    .frame(height: 24)
                    .submitLabel(.search)
                    .disabled(isBusy)
                    .onSubmit(onSubmit)
#endif

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.primary)
                        .accessibilityLabel("Searching")
                }
            }
            .padding()
            .fontWeight(.semibold)
            .tint(.primary)
        }
        .glassEffect(.regular.interactive(true), in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
}

/// Bottom launch cluster that keeps the search, settings, and capture glass in one shared context.
struct RewindControlBar: View {
    private let namespace: Namespace.ID
    private let searchTransitionID: String
    private let settingsTransitionID: String
    private let captureTransitionID: String
    private let onSearch: () -> Void
    private let onSettings: () -> Void
    private let onCapture: () -> Void

    init(
        namespace: Namespace.ID,
        searchTransitionID: String,
        settingsTransitionID: String,
        captureTransitionID: String,
        onSearch: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onCapture: @escaping () -> Void
    ) {
        self.namespace = namespace
        self.searchTransitionID = searchTransitionID
        self.settingsTransitionID = settingsTransitionID
        self.captureTransitionID = captureTransitionID
        self.onSearch = onSearch
        self.onSettings = onSettings
        self.onCapture = onCapture
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                SettingsButton(action: onSettings, namespace: namespace, transitionID: settingsTransitionID)

                SearchLaunchButton(action: onSearch, namespace: namespace, transitionID: searchTransitionID)

                CaptureButton(action: onCapture, namespace: namespace, transitionID: captureTransitionID)
            }
        }
    }
}

/// Search launcher used on Today before the full-screen search experience opens.
struct SearchLaunchButton: View {
    let action: () -> Void
    let namespace: Namespace.ID
    let transitionID: String

    var body: some View {
        Button(action: action) {
            VStack {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")

                    Text("Search")

                    Spacer(minLength: 0)
                }
                .padding()
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .tint(.primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
            .matchedTransitionSource(id: transitionID, in: namespace) { source in
                source.clipShape(.rect(cornerRadius: 28, style: .continuous))
            }
            .glassEffect(.regular.interactive(true), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open search")
        .frame(maxWidth: .infinity)
    }
}

/// Standalone settings entry point used beside search controls.
struct SettingsButton: View {
    let action: () -> Void
    let namespace: Namespace.ID
    let transitionID: String

    var body: some View {
        Button(action: action) {
            Image(systemName: "gear")
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 52, height: 52)
                .contentShape(Circle())
                .matchedTransitionSource(id: transitionID, in: namespace) { source in
                    source.clipShape(.rect(cornerRadius: 26, style: .continuous))
                }
                .glassEffect(.regular.interactive(true), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open settings")
    }
}

/// Standalone capture entry point used beside search controls.
struct CaptureButton: View {
    let action: () -> Void
    let namespace: Namespace.ID
    let transitionID: String

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 52, height: 52)
                .contentShape(Circle())
                .matchedTransitionSource(id: transitionID, in: namespace) { source in
                    source.clipShape(.rect(cornerRadius: 26, style: .continuous))
                }
                .glassEffect(.regular.interactive(true), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start capture")
    }
}

#Preview {
    @Previewable @Namespace var namespace

    ScrollView {

    }
    .background(.red)
    .safeAreaInset(edge: .bottom) {
        RewindControlBar(
            namespace: namespace,
            searchTransitionID: "search",
            settingsTransitionID: "settings",
            captureTransitionID: "capture",
            onSearch: {},
            onSettings: {},
            onCapture: {}
        )
            .padding()
    }
}
