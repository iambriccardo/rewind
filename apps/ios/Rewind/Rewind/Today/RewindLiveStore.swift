//
//  RewindLiveStore.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

import Foundation
import Observation
import OSLog

/// UI-facing adapter for the live Rewind phone protocol.
///
/// The store owns the capture controller and subscribes to backend protocol events.
/// Views render this state but do not perform network, upload, or AVFoundation work.
@MainActor
@Observable
final class RewindLiveStore {
    let captureController: PhoneCaptureController

    private(set) var status: LiveStatus = .starting
    private(set) var sessionID: String?
    private(set) var latestAgentText: String?
    private(set) var currentSaveRequest: RewindSaveRequest?
    private(set) var lastCommittedFrameCount: Int?
    private(set) var searchResults: [RewindSearchResultCard] = []
    private(set) var searchQuery: String?
    private(set) var searchError: String?
    private(set) var isSearchBusy = false
    /// Changes whenever the backend delivers a search result batch.
    ///
    /// Voice prompts can ask Rewind to find memories without the text search field
    /// ever becoming active, so the view observes this token to present results.
    private(set) var searchResultsPresentationID = UUID()
    private(set) var saveWaveID = UUID()
    private(set) var latestCachedFrame: CachedCaptureFrame?

    @ObservationIgnored private let endpoint: CaptureStreamEndpoint
    @ObservationIgnored private let frameCache: CaptureFrameCache
#if os(iOS)
    @ObservationIgnored private let audioPlayer = AgentAudioPlayer()
    @ObservationIgnored private let locationProvider = RewindLocationProvider()
#endif
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vogelhaus.Rewind",
        category: "RewindLiveStore"
    )
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var cachedFrameTask: Task<Void, Never>?
    @ObservationIgnored private var saveCommitTask: Task<Void, Never>?
    @ObservationIgnored private var wantsCaptureActive = false

    init(
        endpoint: CaptureStreamEndpoint = CaptureStreamEndpoint(),
        frameCache: CaptureFrameCache = .shared
    ) {
        self.endpoint = endpoint
        self.frameCache = frameCache
        self.captureController = PhoneCaptureController(endpoint: endpoint, frameCache: frameCache)
    }

    var isLive: Bool {
        sessionID != nil && captureController.isRunning
    }

    var isSaving: Bool {
        currentSaveRequest != nil
    }

    func start() async {
        wantsCaptureActive = true
        startEventListenerIfNeeded()
        startRetryLoopIfNeeded()
        startCachedFrameListenerIfNeeded()

        if captureController.state == .idle {
            status = .starting
            await captureController.start()
        }

        guard wantsCaptureActive else {
            await stop()
            return
        }

        if case let .failed(message) = captureController.state {
            status = .failed(message)
        } else if sessionID == nil, captureController.isRunning {
            status = .connecting("Camera is live. Connecting to Rewind.")
        }
    }

    func stop() async {
        wantsCaptureActive = false
        guard captureController.state != .idle else {
            return
        }

        await captureController.stop()
        saveCommitTask?.cancel()
        saveCommitTask = nil
        sessionID = nil
        currentSaveRequest = nil
        isSearchBusy = false
#if os(iOS)
        audioPlayer.stop()
#endif
        status = .paused
    }

    func submitSearch(_ query: String) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !isSearchBusy else {
            return
        }

        isSearchBusy = true
        searchQuery = trimmedQuery
        searchError = nil
        status = .searching(trimmedQuery)
        await endpoint.search(query: trimmedQuery)
    }

    private func startEventListenerIfNeeded() {
        guard eventTask == nil else {
            return
        }

        eventTask = Task { [endpoint] in
            for await event in endpoint.events {
                await handle(event)
            }
        }
    }

    private func startRetryLoopIfNeeded() {
        guard retryTask == nil else {
            return
        }

        retryTask = Task { [endpoint] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if sessionID == nil, captureController.isRunning {
                    await endpoint.reconnectActiveSession()
                }
            }
        }
    }

    private func startCachedFrameListenerIfNeeded() {
        guard cachedFrameTask == nil else {
            return
        }

        cachedFrameTask = Task { [captureController] in
            for await cachedFrame in captureController.cachedFrames {
                latestCachedFrame = cachedFrame
            }
        }
    }

    private func handle(_ event: RewindProtocolEvent) async {
        guard wantsCaptureActive else {
            return
        }

        switch event {
        case let .status(text):
            if sessionID == nil {
                status = .connecting(text)
            } else {
                status = .live(text)
            }
        case let .sessionReady(session):
            sessionID = session.sessionID
            status = .live("Listening")
        case let .saveRequest(request):
            currentSaveRequest = request
            lastCommittedFrameCount = nil
            saveWaveID = UUID()
            status = .saving(request.title)
            saveCommitTask?.cancel()
#if os(iOS)
            saveCommitTask = Task { [endpoint, locationProvider] in
                let location = await locationProvider.currentLocation()
                guard !Task.isCancelled else {
                    return
                }
                await endpoint.commit(request, location: location)
            }
#else
            saveCommitTask = Task { [endpoint] in
                await endpoint.commit(request, location: nil)
            }
#endif
        case let .rewindCommitted(request, frameCount):
            saveCommitTask = nil
            currentSaveRequest = nil
            lastCommittedFrameCount = frameCount
            status = .saved(request.title, frameCount)
        case let .searchResults(results):
            searchResults = await makeResultCards(from: results)
            searchQuery = results.query
            searchError = nil
            isSearchBusy = false
            searchResultsPresentationID = UUID()
            status = .searchComplete(results.results.count, results.query)
        case let .agentText(text):
            latestAgentText = text
        case let .agentAudio(audio):
#if os(iOS)
            audioPlayer.play(audio)
#endif
        case let .failed(message, scope):
            let wasSearching = isSearchBusy
            if scope == .connection {
                sessionID = nil
                saveCommitTask?.cancel()
                saveCommitTask = nil
#if os(iOS)
                audioPlayer.stop()
#endif
            }
            isSearchBusy = false
            if scope == .connection || !wasSearching {
                saveCommitTask = nil
                currentSaveRequest = nil
            }
            if wasSearching {
                searchError = message
            }
            status = scope == .connection ? .failed(message) : .operationFailed(message)
            logger.error("Live protocol failed: \(message, privacy: .public)")
        }
    }

    private func makeResultCards(from results: RewindSearchResults) async -> [RewindSearchResultCard] {
        var cards: [RewindSearchResultCard] = []

        for result in results.results {
            let frameURLs = await contextualFrameURLs(for: result)

            cards.append(RewindSearchResultCard(
                id: result.eventID,
                title: result.title,
                description: result.description,
                entities: result.entities,
                locationHint: result.locationHint,
                frameURLs: frameURLs,
                score: result.score.similarity ?? result.score.eventSimilarity
            ))
        }

        return cards
    }

    private func contextualFrameURLs(for result: RewindProtocolResult) async -> [URL] {
        guard let targetDate = Self.resultReferenceDate(for: result) else {
            logger.info("Search result \(result.eventID, privacy: .public) did not include a timestamp for phone frame matching")
            return []
        }

        let maximumDistance = Self.resultImageMatchWindow(for: result)
        let frames = await frameCache.frameWindow(
            near: targetDate,
            frameCountBeforeAndAfter: 10,
            maximumDistance: maximumDistance
        )

        guard !frames.isEmpty else {
            logger.info(
                "No cached phone frame window matched search result \(result.eventID, privacy: .public) within \(maximumDistance, privacy: .public) seconds"
            )
            return []
        }

        return frames.map(\.fileURL)
    }

    private static func resultReferenceDate(for result: RewindProtocolResult) -> Date? {
        let startedAt = result.startedAt.flatMap(date(from:))
        let endedAt = result.endedAt.flatMap(date(from:))

        if let startedAt, let endedAt {
            return startedAt.addingTimeInterval(endedAt.timeIntervalSince(startedAt) / 2)
        }

        return startedAt ?? endedAt
    }

    private static func resultImageMatchWindow(for result: RewindProtocolResult) -> TimeInterval {
        guard
            let startedAt = result.startedAt.flatMap(date(from:)),
            let endedAt = result.endedAt.flatMap(date(from:))
        else {
            return 15
        }

        let eventDuration = abs(endedAt.timeIntervalSince(startedAt))
        return min(max(eventDuration / 2 + 10, 15), 120)
    }

    private static func date(from string: String) -> Date? {
        ISO8601DateFormatter.rewindProtocol.date(from: string)
    }
}

enum LiveStatus: Equatable {
    case starting
    case connecting(String)
    case live(String)
    case saving(String)
    case saved(String, Int)
    case searching(String)
    case searchComplete(Int, String)
    case failed(String)
    case operationFailed(String)
    case paused

    var title: String {
        switch self {
        case .starting:
            "Starting"
        case .connecting:
            "Connecting"
        case .live:
            "Listening"
        case .saving:
            "Saving"
        case .saved:
            "Saved"
        case .searching:
            "Searching"
        case .searchComplete:
            "Results"
        case .failed:
            "Offline"
        case .operationFailed:
            "Issue"
        case .paused:
            "Paused"
        }
    }

    var detail: String {
        switch self {
        case .starting:
            "Opening camera and microphone."
        case let .connecting(message):
            message
        case let .live(message):
            message
        case let .saving(title):
            "Capturing the frame window for \(title)."
        case let .saved(title, frameCount):
            "\(title) saved with \(frameCount) frames."
        case let .searching(query):
            "Looking for \(query)."
        case let .searchComplete(count, query):
            "\(count) result\(count == 1 ? "" : "s") for \(query)."
        case let .failed(message):
            message
        case let .operationFailed(message):
            message
        case .paused:
            "Rewind resumes when the app is active."
        }
    }
}

struct RewindSearchResultCard: Identifiable, Sendable {
    let id: String
    let title: String
    let description: String
    let entities: [String]
    let locationHint: String?
    let frameURLs: [URL]
    let score: Double?
}
