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

    init(
        searchText: Binding<String>,
        isFocused: FocusState<Bool>.Binding
    ) {
        self._searchText = searchText
        self.isFocused = isFocused
    }

    var body: some View {
        VStack {
            HStack {
                Image(systemName: "magnifyingglass")

                TextField("Search", text: $searchText)
                    .focused(isFocused)
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
