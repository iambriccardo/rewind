//
//  RewindProtocolClient.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

import Foundation
import OSLog

/// Actor-owned client for the Rewind product protocol.
///
/// This is the iOS equivalent of the browser simulator in `apps/web/public/phone.html`:
/// it performs health checks, opens `/v1/live`, sends `session.hello`, streams media,
/// commits rewind frame windows over HTTP, and emits backend messages to UI stores.
actor RewindProtocolClient {
    let events: AsyncStream<RewindProtocolEvent>

    private let configuration: RewindConfiguration
    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let continuation: AsyncStream<RewindProtocolEvent>.Continuation
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vogelhaus.Rewind",
        category: "RewindProtocolClient"
    )

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var mediaSequence = 0
    private var ready = false

    init(configuration: RewindConfiguration = .defaultConfiguration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession

        var streamContinuation: AsyncStream<RewindProtocolEvent>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func checkHealth() async throws {
        try configuration.validateForCurrentRuntime()
        let (data, response) = try await urlSession.data(from: configuration.httpURL(path: "/health"))
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw RewindProtocolError.unhealthyBackend
        }

        struct Health: Decodable {
            let ok: Bool
        }

        guard try decoder.decode(Health.self, from: data).ok else {
            throw RewindProtocolError.unhealthyBackend
        }
    }

    func reportFailure(_ message: String, scope: RewindProtocolFailureScope = .operation) {
        continuation.yield(.failed(message, scope))
    }

    func connect(hello: RewindSessionHello) async throws {
        if ready, webSocketTask != nil {
            return
        }

        try await checkHealth()
        closeWebSocket()

        let task = urlSession.webSocketTask(with: configuration.liveWebSocketURL)
        webSocketTask = task
        ready = false
        mediaSequence = 0
        task.resume()
        continuation.yield(.status("Realtime handshaking"))
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        do {
            try await send(hello)
            logger.info("Opened Rewind live socket")
        } catch {
            closeWebSocket()
            ready = false
            throw error
        }
    }

    func disconnect() async {
        try? await send(RewindMediaEndMessage(modality: "image"))
        try? await send(RewindMediaEndMessage(modality: "audio"))
        closeWebSocket()
        ready = false
        continuation.yield(.status("Realtime disconnected"))
    }

    func sendText(_ text: String) async throws {
        try await send(RewindUserTextMessage(text: text))
    }

    func sendImageFrame(_ frame: RewindBufferedFrame) async throws {
        guard ready else {
            return
        }

        mediaSequence += 1
        try await send(RewindUserMediaMessage(
            modality: "image",
            mimeType: "image/jpeg",
            data: frame.jpegData.base64EncodedString(),
            seq: mediaSequence,
            timestamp: ISO8601DateFormatter.rewindProtocol.string(from: frame.capturedAt)
        ))
    }

    func sendAudioChunk(_ chunk: CaptureAudioChunk) async throws {
        guard ready else {
            return
        }

        mediaSequence += 1
        try await send(RewindUserMediaMessage(
            modality: "audio",
            mimeType: chunk.mimeType,
            data: chunk.data.base64EncodedString(),
            seq: mediaSequence,
            timestamp: ISO8601DateFormatter.rewindProtocol.string(from: chunk.timestamp)
        ))
    }

    @discardableResult
    func commit(
        saveRequest: RewindSaveRequest,
        window: RewindCaptureWindow,
        frames: [RewindBufferedFrame],
        location: RewindCapturedLocation?
    ) async throws -> Int {
        guard !frames.isEmpty else {
            throw RewindProtocolError.noBufferedFrames
        }

        let localAssetID = "local-\(saveRequest.eventID)"
        let startedAt = frames.first.map { ISO8601DateFormatter.rewindProtocol.string(from: $0.capturedAt) }
        let endedAt = frames.last.map { ISO8601DateFormatter.rewindProtocol.string(from: $0.capturedAt) }
        let clientContext = RewindSessionHello.Context.current()

        let commitRequest = RewindCommitRequest(
            eventID: saveRequest.eventID,
            localAssetID: localAssetID,
            thumbnailFrameUUID: frames.last?.id,
            startedAt: startedAt,
            endedAt: endedAt,
            location: location.map { capturedLocation in
                RewindCommitRequest.Location(
                    latitude: capturedLocation.latitude,
                    longitude: capturedLocation.longitude
                )
            },
            frames: frames.enumerated().map { index, frame in
                RewindCommitRequest.Frame(
                    deviceFrameUUID: frame.id,
                    localAssetID: localAssetID,
                    capturedAt: ISO8601DateFormatter.rewindProtocol.string(from: frame.capturedAt),
                    offsetMs: Self.offsetMilliseconds(for: frame, in: window, fallbackIndex: index),
                    imageBase64: saveRequest.includeFrameImages ? frame.jpegData.base64EncodedString() : nil,
                    mimeType: saveRequest.includeFrameImages ? "image/jpeg" : nil
                )
            },
            metadata: RewindCommitRequest.Metadata(
                rewindDurationMs: window.durationMs,
                captureAnchorUTC: window.anchorUTC,
                captureDurationMs: window.durationMs,
                captureWindowStartedAt: window.startedAtUTC,
                captureWindowEndedAt: window.endedAtUTC,
                frameEmbeddingMode: saveRequest.frameEmbeddingMode,
                clientTimeZone: clientContext.timeZone,
                clientUTCOffsetMinutes: clientContext.utcOffsetMinutes,
                locationAccuracyMeters: location?.accuracyMeters,
                locationCapturedAt: location.map { ISO8601DateFormatter.rewindProtocol.string(from: $0.capturedAt) }
            )
        )

        var request = URLRequest(url: configuration.httpURL(path: saveRequest.uploadURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.userID, forHTTPHeaderField: "x-user-id")
        request.setValue(configuration.deviceID, forHTTPHeaderField: "x-device-id")
        request.httpBody = try encoder.encode(commitRequest)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw RewindProtocolError.uploadFailed(String(data: data, encoding: .utf8) ?? "upload failed")
        }

        logger.info("Committed rewind \(saveRequest.eventID, privacy: .public) with \(frames.count, privacy: .public) frame references")
        continuation.yield(.rewindCommitted(saveRequest, frames.count))
        return frames.count
    }

    func search(query: String) async throws {
        var request = URLRequest(url: configuration.httpURL(path: "/v1/rewinds/search"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.userID, forHTTPHeaderField: "x-user-id")
        request.setValue(configuration.deviceID, forHTTPHeaderField: "x-device-id")
        request.httpBody = try encoder.encode(RewindSearchRequest(
            query: query,
            limit: 10,
            clientContext: .current()
        ))

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw RewindProtocolError.searchFailed(String(data: data, encoding: .utf8) ?? "search failed")
        }

        let results = try decoder.decode(RewindSearchResults.self, from: data)
        continuation.yield(.searchResults(results))
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let webSocketTask else {
                return
            }

            do {
                let message = try await webSocketTask.receive()
                let data: Data
                switch message {
                case let .data(messageData):
                    data = messageData
                case let .string(text):
                    data = Data(text.utf8)
                @unknown default:
                    continue
                }

                try await handleServerMessage(RewindProtocolDecoder.decode(data, using: decoder))
            } catch {
                if !Task.isCancelled {
                    if self.webSocketTask === webSocketTask {
                        ready = false
                        self.webSocketTask = nil
                        continuation.yield(.failed(error.localizedDescription, .connection))
                    }
                    logger.error("Rewind live socket receive failed: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
        }
    }

    private func closeWebSocket() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private func handleServerMessage(_ message: RewindServerMessage) async throws {
        switch message {
        case let .sessionReady(session):
            ready = true
            continuation.yield(.sessionReady(session))
            continuation.yield(.status("Realtime connected"))
        case let .liveState(state):
            continuation.yield(.status(state.state))
        case let .agentMessage(text):
            continuation.yield(.agentText(text))
        case let .agentMedia(media):
            if let text = media.text {
                continuation.yield(.agentText(text))
            }
            if media.modality == "audio", let data = media.data {
                continuation.yield(.agentAudio(RewindAgentAudio(
                    mimeType: media.mimeType ?? "audio/pcm;rate=24000",
                    base64Data: data
                )))
            }
        case let .saveRequest(request):
            continuation.yield(.saveRequest(request))
        case let .searchResults(results):
            continuation.yield(.searchResults(results))
        case let .error(message):
            continuation.yield(.failed(message, .connection))
        case let .unknown(type):
            logger.info("Ignored Rewind protocol message type \(type, privacy: .public)")
        }
    }

    private func send<T: Encodable & Sendable>(_ message: T) async throws {
        guard let webSocketTask else {
            throw RewindProtocolError.notConnected
        }

        let data = try encoder.encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RewindProtocolError.encodingFailed
        }

        try await webSocketTask.send(.string(text))
    }

    private nonisolated static func offsetMilliseconds(
        for frame: RewindBufferedFrame,
        in window: RewindCaptureWindow,
        fallbackIndex: Int
    ) -> Int {
        let milliseconds = frame.capturedAt.timeIntervalSince(window.startedAt) * 1_000
        guard milliseconds.isFinite else {
            return fallbackIndex * 1_000
        }

        return max(0, Int(milliseconds.rounded()))
    }
}

enum RewindProtocolEvent: Sendable {
    case status(String)
    case sessionReady(RewindSessionReady)
    case saveRequest(RewindSaveRequest)
    case rewindCommitted(RewindSaveRequest, Int)
    case searchResults(RewindSearchResults)
    case agentText(String)
    case agentAudio(RewindAgentAudio)
    case failed(String, RewindProtocolFailureScope)
}

nonisolated struct RewindAgentAudio: Sendable {
    let mimeType: String
    let base64Data: String
}

enum RewindProtocolFailureScope: Equatable, Sendable {
    case connection
    case operation
}

enum RewindProtocolError: LocalizedError {
    case notConnected
    case unhealthyBackend
    case encodingFailed
    case noBufferedFrames
    case uploadFailed(String)
    case searchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Realtime socket is not connected."
        case .unhealthyBackend:
            "Backend is unavailable."
        case .encodingFailed:
            "Could not encode a protocol message."
        case .noBufferedFrames:
            "No rewind frames are buffered yet."
        case let .uploadFailed(message):
            "Rewind upload failed: \(message)"
        case let .searchFailed(message):
            "Search failed: \(message)"
        }
    }
}

extension ISO8601DateFormatter {
    nonisolated static let rewindProtocol: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
