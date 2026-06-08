//
//  Today.swift
//  Rewind
//
//  Created by Florian Schulte on 6/6/26.
//

import SwiftUI

/// The live Rewind surface.
///
/// This screen keeps the timeline clean by default. Wearable simulation is the
/// primary capture surface, and search opens from explicit UI input.
struct Today: View {
    @State private var timelineStore = CaptureTimelineStore()
    @State private var liveStore = RewindLiveStore()
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var isWearableSimulationPresented = false
    @State private var isSettingsPresented = false
    @State private var shouldFocusSearchOnPresentation = false
    @State private var selectedTimelineDate: Date
    @State private var isTimelineScrubbing = false
    @State private var isTimelineBrowsing = false
    @State private var granularScrubStartDate: Date?
    @State private var granularScrubCurrentFrameID: String?
    @State private var granularScrubFeedbackID = 0
    @State private var latestLocalFrame: CachedCaptureFrame?
    @Namespace private var presentationNamespace

    init(selectedDate: Date = .now) {
        self._selectedTimelineDate = State(initialValue: selectedDate)
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            LiveMemorySurface(
                liveStore: liveStore,
                timelineStore: timelineStore,
                timelineFrame: timelineFrame,
                latestLocalFrame: latestLocalFrame,
                prefersCameraPreview: false
            )
            .contentShape(Rectangle())
            .gesture(granularScrubGesture)

            if !isSearchPresented, let visibleRange = timelineStore.visibleRange {
                HStack {
                    Spacer()

                    Scrubber(
                        selection: $selectedTimelineDate,
                        isScrubbing: $isTimelineScrubbing,
                        startDate: visibleRange.start,
                        endDate: visibleRange.end,
                        availableIntervals: timelineStore.availableIntervals,
                        protectedVerticalInsets: scrubberProtectedInsets
                    )
                    .ignoresSafeArea(edges: .vertical)
                }
                .ignoresSafeArea(edges: .vertical)
                .zIndex(2)
            }
        }
        .safeAreaInset(edge: .bottom) {
            RewindControlBar(
                namespace: presentationNamespace,
                searchTransitionID: Self.searchTransitionID,
                settingsTransitionID: Self.settingsTransitionID,
                captureTransitionID: Self.captureTransitionID
            ) {
                presentSearch()
            } onSettings: {
                presentSettings()
            } onCapture: {
                presentWearableSimulation()
            }
            .padding(.horizontal, 32)
        }
        .fullScreenCover(isPresented: $isSearchPresented, onDismiss: dismissSearch) {
            SearchExperience(
                searchText: $searchText,
                isSearching: liveStore.isSearchBusy,
                errorMessage: liveStore.searchError,
                results: liveStore.searchResults,
                focusOnAppear: shouldFocusSearchOnPresentation
            ) {
                dismissSearch()
            } onSubmit: {
                Task {
                    await submitSearch()
                }
            }
            .navigationTransition(.zoom(sourceID: Self.searchTransitionID, in: presentationNamespace))
            .presentationBackground(.black)
        }
        .fullScreenCover(isPresented: $isWearableSimulationPresented) {
            WearableSimulationView()
                .navigationTransition(.zoom(sourceID: Self.captureTransitionID, in: presentationNamespace))
        }
        .fullScreenCover(isPresented: $isSettingsPresented, onDismiss: {
            Task {
                await reloadLatestTimeline()
            }
        }) {
            RewindSettingsView()
                .navigationTransition(.zoom(sourceID: Self.settingsTransitionID, in: presentationNamespace))
        }
        .onChange(of: isWearableSimulationPresented) { _, isPresented in
            guard !isPresented else {
                return
            }

            Task {
                await reloadLatestTimeline()
            }
        }
        .task {
            await loadLatestTimeline()
        }
        .onChange(of: liveStore.latestCachedFrame) { _, frame in
            guard let frame else {
                return
            }

            latestLocalFrame = frame
            Task {
                await loadTimeline(containing: frame.timestamp)
            }
        }
        .onDisappear {
            isTimelineScrubbing = false
            granularScrubStartDate = nil
            granularScrubCurrentFrameID = nil
        }
        .onChange(of: isTimelineScrubbing) { _, isScrubbing in
            if isScrubbing {
                isTimelineBrowsing = true
            }
        }
        .onChange(of: selectedTimelineDate) { _, _ in
            if isSelectedTimelineAtNow {
                isTimelineBrowsing = false
                granularScrubStartDate = nil
                granularScrubCurrentFrameID = nil
            } else {
                isTimelineBrowsing = true
            }

        }
        .sensoryFeedback(.selection, trigger: granularScrubFeedbackID)
    }

    private func presentSearch() {
        shouldFocusSearchOnPresentation = true
        withAnimation(.smooth(duration: 0.22)) {
            isSearchPresented = true
        }
    }

    private func dismissSearch() {
        isSearchPresented = false
        shouldFocusSearchOnPresentation = false
    }

    private func presentWearableSimulation() {
        dismissSearch()
        isTimelineBrowsing = false
        granularScrubStartDate = nil

        isWearableSimulationPresented = true
    }

    private func presentSettings() {
        isSettingsPresented = true
    }

    private func submitSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return
        }

        if !isSearchPresented {
            presentSearch()
        }

        await liveStore.submitSearch(query)
    }

    private func loadTimeline(containing date: Date = .now) async {
        await timelineStore.loadDay(containing: date)
        if !isTimelineBrowsing {
            selectedTimelineDate = timelineStore.initialSelection(preferredDate: date)
        }
        latestLocalFrame = timelineStore.frames.last
    }

    private func loadLatestTimeline() async {
        let latestFrame = await timelineStore.loadLatestAvailableDay()
        let selectedFrame = latestFrame ?? timelineStore.frames.last
        if !isTimelineBrowsing {
            selectedTimelineDate = selectedFrame?.timestamp ?? .now
        }
        latestLocalFrame = selectedFrame
    }

    private func reloadLatestTimeline() async {
        isTimelineBrowsing = false
        isTimelineScrubbing = false
        granularScrubStartDate = nil
        await loadLatestTimeline()
    }

    private var timelineFrame: CachedCaptureFrame? {
        guard isTimelineBrowsing else {
            return nil
        }

        return timelineStore.timelineFrame(for: selectedTimelineDate)
    }

    private var isSelectedTimelineAtNow: Bool {
        Self.isNow(selectedTimelineDate)
    }

    private var granularScrubGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                guard !isSearchPresented, isTimelineBrowsing else {
                    return
                }

                if granularScrubStartDate == nil {
                    granularScrubStartDate = selectedTimelineDate
                    granularScrubCurrentFrameID = timelineStore.timelineFrame(for: selectedTimelineDate)?.id
                }

                let startDate = granularScrubStartDate ?? selectedTimelineDate
                let horizontalDelta = value.translation.width * Self.granularScrubSecondsPerPoint
                let verticalDelta = -value.translation.height * Self.granularScrubSecondsPerPoint
                let proposedDate = startDate.addingTimeInterval(horizontalDelta + verticalDelta)
                let nextSelectionDate = timelineStore.timelineSelectionDate(for: proposedDate)
                selectedTimelineDate = nextSelectionDate
                updateGranularScrubFeedback(for: nextSelectionDate)
            }
            .onEnded { _ in
                granularScrubStartDate = nil
                granularScrubCurrentFrameID = nil
            }
    }

    private func updateGranularScrubFeedback(for date: Date) {
        guard let frame = timelineStore.timelineFrame(for: date), frame.id != granularScrubCurrentFrameID else {
            return
        }

        granularScrubCurrentFrameID = frame.id
        granularScrubFeedbackID += 1
    }

    private var scrubberProtectedInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: 0, bottom: 96, trailing: 0)
    }

    private static let searchTransitionID = "today-search"
    private static let settingsTransitionID = "today-settings"
    private static let captureTransitionID = "today-capture"
    private static let nowSelectionTolerance: TimeInterval = 3
    private static let granularScrubSecondsPerPoint: TimeInterval = 0.18

    private static func isNow(_ date: Date) -> Bool {
        abs(date.timeIntervalSince(.now)) <= nowSelectionTolerance
    }
}

#Preview("Today") {
    Today(selectedDate: .now)
}

private struct LiveMemorySurface: View {
    let liveStore: RewindLiveStore
    let timelineStore: CaptureTimelineStore
    let timelineFrame: CachedCaptureFrame?
    let latestLocalFrame: CachedCaptureFrame?
    let prefersCameraPreview: Bool

    var body: some View {
        ZStack {
            memorySurface
                .ignoresSafeArea()

            LiveSaveRipple(saveWaveID: liveStore.saveWaveID)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var memorySurface: some View {
#if os(iOS)
        if prefersCameraPreview, canShowCameraPreview {
            PhoneCameraPreviewSurface(session: liveStore.captureController.previewSession)
        } else if let timelineFrame {
            MemoryImageSurface(imageSource: .file(url: timelineFrame.fileURL))
        } else if prefersLiveCameraSurface {
            PhoneCameraPreviewSurface(session: liveStore.captureController.previewSession)
        } else if let latestLocalFrame {
            MemoryImageSurface(imageSource: .file(url: latestLocalFrame.fileURL))
        } else if let frame = timelineStore.frames.last {
            MemoryImageSurface(imageSource: .file(url: frame.fileURL))
        } else if case .failed = liveStore.captureController.state {
            MemoryImageSurface(imageSource: .asset(name: "memory-example-3027"))
        } else {
            EmptyMemorySurface()
        }
#else
        if let timelineFrame {
            MemoryImageSurface(imageSource: .file(url: timelineFrame.fileURL))
        } else if let latestLocalFrame {
            MemoryImageSurface(imageSource: .file(url: latestLocalFrame.fileURL))
        } else if let frame = timelineStore.frames.last {
            MemoryImageSurface(imageSource: .file(url: frame.fileURL))
        } else {
            EmptyMemorySurface()
        }
#endif
    }

    private var prefersLiveCameraSurface: Bool {
        switch liveStore.captureController.state {
        case .running:
            true
        case .idle, .requestingAccess, .stopping, .failed:
            false
        }
    }

    private var canShowCameraPreview: Bool {
        switch liveStore.captureController.state {
        case .running:
            true
        case .idle, .requestingAccess, .stopping, .failed:
            false
        }
    }
}

private struct LiveSaveRipple: View {
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

private struct SearchExperience: View {
    @Binding var searchText: String
    @State private var requestSearchFocus = false
    @State private var isSearchFieldFocused = false
    @State private var focusedResult: RewindSearchResultCard?
    @Namespace private var searchResultFocusNamespace
    let isSearching: Bool
    let errorMessage: String?
    let results: [RewindSearchResultCard]
    let focusOnAppear: Bool
    let onBack: () -> Void
    let onSubmit: () -> Void

    init(
        searchText: Binding<String>,
        isSearching: Bool,
        errorMessage: String?,
        results: [RewindSearchResultCard],
        focusOnAppear: Bool,
        onBack: @escaping () -> Void,
        onSubmit: @escaping () -> Void
    ) {
        self._searchText = searchText
        self.isSearching = isSearching
        self.errorMessage = errorMessage
        self.results = results
        self.focusOnAppear = focusOnAppear
        self.onBack = onBack
        self.onSubmit = onSubmit
    }

    var body: some View {
        NavigationStack {
            SearchResultsSurface(
                isSearching: isSearching,
                errorMessage: errorMessage,
                results: results,
                namespace: searchResultFocusNamespace
            ) { result in
                presentFocusedResult(result)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                SearchBar(
                    searchText: $searchText,
                    requestFocus: $requestSearchFocus,
                    isFocused: $isSearchFieldFocused,
                    isBusy: isSearching,
                    onSubmit: onSubmit
                )
                .padding()
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .toolbarBackground(.hidden, for: .navigationBar)
        .overlay {
            if let focusedResult {
                SearchResultFocusOverlay(
                    result: focusedResult,
                    namespace: searchResultFocusNamespace,
                    matchedGeometryID: matchedGeometryID(for: focusedResult)
                ) {
                    self.focusedResult = nil
                }
                .ignoresSafeArea()
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.82).combined(with: .opacity),
                    removal: .scale(scale: 0.92).combined(with: .opacity)
                ))
                .zIndex(20)
            }
        }
        .task(id: focusOnAppear) {
            if focusOnAppear {
                requestSearchFocus = true
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.72), value: focusedResult?.id)
    }

    private func presentFocusedResult(_ result: RewindSearchResultCard) {
        guard !result.frameURLs.isEmpty else {
            return
        }

        requestSearchFocus = false
        isSearchFieldFocused = false
        focusedResult = result
    }

    private func matchedGeometryID(for result: RewindSearchResultCard) -> String {
        "search-result-\(result.id)"
    }
}

private struct EmptyMemorySurface: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black)

            ContentUnavailableView("No camera", systemImage: "camera.viewfinder")
                .foregroundStyle(.white)
        }
    }
}

private struct SearchResultsSurface: View {
    let isSearching: Bool
    let errorMessage: String?
    let results: [RewindSearchResultCard]
    let namespace: Namespace.ID
    let onFocusResult: (RewindSearchResultCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let errorMessage {
                ContentUnavailableView {
                    Label("Search unavailable", systemImage: "magnifyingglass")
                } description: {
                    Text(errorMessage)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                if isSearching {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Search any moment", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try a place, object, person, or something that happened earlier.")
                    }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 12) {
                        ForEach(results) { result in
                            SearchResultTile(
                                result: result,
                                namespace: namespace,
                                matchedGeometryID: "search-result-\(result.id)"
                            ) {
                                onFocusResult(result)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 120)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.clear)
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }
}

private struct SearchResultTile: View {
    let result: RewindSearchResultCard
    let namespace: Namespace.ID
    let matchedGeometryID: String
    let onFocus: () -> Void

    var body: some View {
        Button(action: onFocus) {
            ZStack(alignment: .bottomLeading) {
                resultImage

                LinearGradient(
                    colors: [.clear, .black.opacity(0.12), .black.opacity(0.78)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                Text(result.title)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 20)
            }
        }
        .buttonStyle(.plain)
        .disabled(result.frameURLs.isEmpty)
        .aspectRatio(0.78, contentMode: .fit)
        .matchedGeometryEffect(id: matchedGeometryID, in: namespace)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(result.title)
        .accessibilityHint(result.frameURLs.isEmpty ? "" : "Open preview.")
    }

    @ViewBuilder
    private var resultImage: some View {
        if !result.frameURLs.isEmpty {
            LoopingSearchResultMemoryCard(frameURLs: result.frameURLs, cornerRadius: Self.cornerRadius)
        } else {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.white.opacity(0.08))
        }
    }

    private static let cornerRadius: CGFloat = 44
}
