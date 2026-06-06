//
//  Today.swift
//  Rewind
//
//  Created by Florian Schulte on 6/6/26.
//

import SwiftUI

/// The day timeline surface that places memory imagery behind the scrubber.
struct Today: View {
    @State private var selectedDate: Date
    @State private var timelineStore = CaptureTimelineStore()
    @State private var routes: [TodayRoute] = []
    @State private var presentedSheet: TodaySheet?
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private let initialDate: Date

    init(
        selectedDate: Date = .now
    ) {
        self.initialDate = selectedDate
        self._selectedDate = State(initialValue: selectedDate)
    }

    var body: some View {
        NavigationStack(path: $routes) {
            ZStack {
                if isSearchFocused {
                    SearchResultsSurface()
                } else {
                    memorySurface
                        .ignoresSafeArea()

                    HStack {
                        Spacer()

                        if let visibleRange = timelineStore.visibleRange {
                            Scrubber(
                                selection: $selectedDate,
                                startDate: visibleRange.start,
                                endDate: visibleRange.end,
                                availableIntervals: timelineStore.availableIntervals,
                                protectedVerticalInsets: scrubberProtectedInsets
                            )
                            .ignoresSafeArea(edges: .vertical)
                        }
                    }
                    .ignoresSafeArea(edges: .vertical)
                    .zIndex(2)
                }
            }
            .toolbar {
                if isSearchFocused {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            isSearchFocused = false
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            presentedSheet = .settings
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
            }
            .sheet(item: $presentedSheet) { sheet in
                switch sheet {
                case .settings:
                    TodaySettings {
                        presentedSheet = nil
                        routes.append(.captureMode)
                    }
                }
            }
            .navigationDestination(for: TodayRoute.self) { route in
                switch route {
                case .captureMode:
                    CaptureMode()
                }
            }
            .task {
                await loadTimeline(selecting: initialDate)
            }
            .onChange(of: routes) { _, nextRoutes in
                guard nextRoutes.isEmpty else {
                    return
                }

                Task {
                    await loadTimeline(selecting: selectedDate)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            SearchBar(searchText: $searchText, isFocused: $isSearchFocused)
                .padding()
                .background(Color.black.opacity(isSearchFocused ? 1 : 0))
        }
    }

    @ViewBuilder
    private var memorySurface: some View {
        if let frame = timelineStore.nearestFrame(to: selectedDate) {
            MemoryImageSurface(imageSource: .file(url: frame.fileURL))
        } else {
            EmptyMemorySurface()
        }
    }

    private var scrubberProtectedInsets: EdgeInsets {
        EdgeInsets(
            top: 56,
            leading: 0,
            bottom: 96,
            trailing: 0
        )
    }

    private func loadTimeline(selecting preferredDate: Date) async {
        await timelineStore.loadDay(containing: preferredDate)
        selectedDate = timelineStore.initialSelection(preferredDate: preferredDate)
    }
}

private enum TodayRoute: Hashable {
    case captureMode
}

private enum TodaySheet: Identifiable {
    case settings

    var id: Self { self }
}

#Preview("Today") {
    Today(selectedDate: .now)
}

private struct EmptyMemorySurface: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black)

            ContentUnavailableView("No Captures", systemImage: "photo.on.rectangle.angled")
                .foregroundStyle(.white)
        }
    }
}

private struct SearchResultsSurface: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Results")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal)
                .padding(.top, 16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black)
    }
}
