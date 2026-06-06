//
//  Today.swift
//  Rewind
//
//  Created by Florian Schulte on 6/6/26.
//

import SwiftUI

/// The live Rewind surface.
///
/// This screen intentionally keeps the capture UI simple: the camera and protocol
/// start automatically, saved memories produce a full-screen ripple, and search
/// opens a separate mode that stays visible until Back is tapped.
struct Today: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var timelineStore = CaptureTimelineStore()
    @State private var liveStore = RewindLiveStore()
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var shouldFocusSearchOnPresentation = false
    @State private var latestLocalFrame: CachedCaptureFrame?
    @FocusState private var isSearchFieldFocused: Bool

    init(selectedDate: Date = .now) {}

    var body: some View {
        ZStack {
            LiveMemorySurface(
                liveStore: liveStore,
                timelineStore: timelineStore,
                latestLocalFrame: latestLocalFrame
            )

            if isSearchPresented {
                SearchExperience(
                    searchText: $searchText,
                    isFocused: $isSearchFieldFocused,
                    isSearching: liveStore.isSearchBusy,
                    query: liveStore.searchQuery ?? searchText,
                    errorMessage: liveStore.searchError,
                    results: liveStore.searchResults,
                    focusOnAppear: shouldFocusSearchOnPresentation
                ) {
                    isSearchPresented = false
                    isSearchFieldFocused = false
                    shouldFocusSearchOnPresentation = false
                } onSubmit: {
                    Task {
                        await submitSearch()
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !isSearchPresented {
                SearchBar(
                    searchText: $searchText,
                    isFocused: $isSearchFieldFocused,
                    isBusy: liveStore.isSearchBusy
                ) {
                    Task {
                        await submitSearch()
                    }
                }
                .padding()
            }
        }
        .onChange(of: isSearchFieldFocused) { _, isFocused in
            guard isFocused, !isSearchPresented else {
                return
            }

            shouldFocusSearchOnPresentation = true
            withAnimation(.smooth(duration: 0.22)) {
                isSearchPresented = true
            }
        }
        .onChange(of: liveStore.searchResultsPresentationID) { _, _ in
            guard liveStore.searchQuery != nil || !liveStore.searchResults.isEmpty else {
                return
            }

            if let searchQuery = liveStore.searchQuery {
                searchText = searchQuery
            }

            guard !isSearchPresented else {
                return
            }

            shouldFocusSearchOnPresentation = false
            isSearchFieldFocused = false
            withAnimation(.smooth(duration: 0.22)) {
                isSearchPresented = true
            }
        }
        .task {
            await loadTimeline()
            await liveStore.start()
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                await handleScenePhase(phase)
            }
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
    }

    private func submitSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return
        }

        if !isSearchPresented {
            shouldFocusSearchOnPresentation = true
            withAnimation(.smooth(duration: 0.22)) {
                isSearchPresented = true
            }
        }

        await liveStore.submitSearch(query)
    }

    private func loadTimeline(containing date: Date = .now) async {
        await timelineStore.loadDay(containing: date)
        latestLocalFrame = timelineStore.frames.last
    }

    private func handleScenePhase(_ phase: ScenePhase) async {
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

#Preview("Today") {
    Today(selectedDate: .now)
}

private struct LiveMemorySurface: View {
    let liveStore: RewindLiveStore
    let timelineStore: CaptureTimelineStore
    let latestLocalFrame: CachedCaptureFrame?

    var body: some View {
        ZStack {
            memorySurface
                .ignoresSafeArea()

            LiveSaveRipple(saveWaveID: liveStore.saveWaveID)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                LiveStatusPill(status: liveStore.status, isLive: liveStore.isLive)
                    .padding(.top, 12)

                Spacer()

                if liveStore.isSaving, let request = liveStore.currentSaveRequest {
                    SavingMemoryBanner(title: request.title)
                        .padding(.bottom, 8)
                } else if let latestAgentText = liveStore.latestAgentText {
                    AgentMessageBanner(text: latestAgentText)
                        .padding(.bottom, 8)
                }
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var memorySurface: some View {
#if os(iOS)
        if prefersLiveCameraSurface {
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
        if let latestLocalFrame {
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
        case .requestingAccess, .running:
            true
        case .idle, .stopping, .failed:
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
    private let isFocused: FocusState<Bool>.Binding
    let isSearching: Bool
    let query: String
    let errorMessage: String?
    let results: [RewindSearchResultCard]
    let focusOnAppear: Bool
    let onBack: () -> Void
    let onSubmit: () -> Void

    init(
        searchText: Binding<String>,
        isFocused: FocusState<Bool>.Binding,
        isSearching: Bool,
        query: String,
        errorMessage: String?,
        results: [RewindSearchResultCard],
        focusOnAppear: Bool,
        onBack: @escaping () -> Void,
        onSubmit: @escaping () -> Void
    ) {
        self._searchText = searchText
        self.isFocused = isFocused
        self.isSearching = isSearching
        self.query = query
        self.errorMessage = errorMessage
        self.results = results
        self.focusOnAppear = focusOnAppear
        self.onBack = onBack
        self.onSubmit = onSubmit
    }

    var body: some View {
        NavigationStack {
            SearchResultsSurface(
                query: query,
                isSearching: isSearching,
                errorMessage: errorMessage,
                results: results
            )
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
                    isFocused: isFocused,
                    isBusy: isSearching,
                    onSubmit: onSubmit
                )
                .padding()
                .background(.black.opacity(0.92))
            }
        }
        .task {
            if focusOnAppear {
                isFocused.wrappedValue = true
            }
        }
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

private struct LiveStatusPill: View {
    let status: LiveStatus
    let isLive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isLive ? "waveform" : "antenna.radiowaves.left.and.right")
                .symbolEffect(.pulse, isActive: isLive)

            VStack(alignment: .leading, spacing: 1) {
                Text(status.title)
                    .font(.caption.weight(.bold))

                Text(status.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct SavingMemoryBanner: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .symbolEffect(.variableColor.iterative, options: .repeating)

            VStack(alignment: .leading, spacing: 2) {
                Text("Saving memory")
                    .font(.subheadline.weight(.semibold))

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AgentMessageBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .lineLimit(2)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SearchResultsSurface: View {
    let query: String
    let isSearching: Bool
    let errorMessage: String?
    let results: [RewindSearchResultCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isSearching ? "Searching" : "Results")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)

                if !query.isEmpty {
                    Text(query)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.top, 16)

            if isSearching {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Search unavailable", systemImage: "magnifyingglass")
                } description: {
                    Text(errorMessage)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                ContentUnavailableView("No results", systemImage: "magnifyingglass")
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 12) {
                        ForEach(results) { result in
                            SearchResultTile(result: result)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 120)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                resultImage
                    .aspectRatio(0.78, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    if !result.entities.isEmpty {
                        Text(result.entities.prefix(2).joined(separator: " · "))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.76))
                            .lineLimit(1)
                    }
                }
                .padding(10)
            }

            Text(result.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var resultImage: some View {
        if !result.frameURLs.isEmpty {
            LoopingMemoryFrameWindow(frameURLs: result.frameURLs)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.08))
                .overlay {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
        }
    }
}

private struct LoopingMemoryFrameWindow: View {
    let frameURLs: [URL]
    @State private var selectedFrameIndex = 0

    var body: some View {
        ZStack {
            if let frameURL = currentFrameURL {
                MemoryImage(source: .file(url: frameURL))
                    .id(frameURL)
                    .transition(.opacity)
            }
        }
        .task(id: frameURLs) {
            await loopFrames()
        }
        .onChange(of: frameURLs) { _, _ in
            selectedFrameIndex = 0
        }
    }

    private var currentFrameURL: URL? {
        guard !frameURLs.isEmpty else {
            return nil
        }

        return frameURLs[min(selectedFrameIndex, frameURLs.count - 1)]
    }

    @MainActor
    private func loopFrames() async {
        guard frameURLs.count > 1 else {
            selectedFrameIndex = 0
            return
        }

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(420))
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            withAnimation(.easeInOut(duration: 0.18)) {
                selectedFrameIndex = (selectedFrameIndex + 1) % frameURLs.count
            }
        }
    }
}
