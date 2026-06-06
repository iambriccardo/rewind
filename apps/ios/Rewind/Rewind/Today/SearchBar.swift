//
//  SearchBar.swift
//  Rewind
//
//  Created by Florian Schulte on 6/6/26.
//

import SwiftUI

/// A bottom search control that reports text and focus changes to its parent
/// surface so the parent can decide when to show search results.
struct SearchBar: View {
    @Binding private var searchText: String
    private let isFocused: FocusState<Bool>.Binding
    private let isBusy: Bool
    private let onSubmit: () -> Void

    init(
        searchText: Binding<String>,
        isFocused: FocusState<Bool>.Binding,
        isBusy: Bool = false,
        onSubmit: @escaping () -> Void = {}
    ) {
        self._searchText = searchText
        self.isFocused = isFocused
        self.isBusy = isBusy
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack {
            HStack {
                Image(systemName: isBusy ? "waveform" : "magnifyingglass")
                    .contentTransition(.symbolEffect(.replace))

                TextField("Search", text: $searchText)
                    .focused(isFocused)
                    .submitLabel(.search)
                    .disabled(isBusy)
                    .onSubmit(onSubmit)
            }
            .padding()
            .fontWeight(.semibold)
            .tint(.primary)
        }
        .glassEffect(.clear.interactive(true), in: Capsule())
    }
}

#Preview {
    @Previewable @State var searchText = ""
    @Previewable @FocusState var isFocused: Bool

    ScrollView {

    }
    .background(.red)
    .safeAreaInset(edge: .bottom) {
        SearchBar(searchText: $searchText, isFocused: $isFocused)
            .padding()
    }
}
