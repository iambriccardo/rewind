//
//  CaptureStreamEndpoint.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

import Foundation
import OSLog

/// Bridges phone capture into the Rewind client protocol.
///
/// `PhoneCaptureController` owns AVFoundation and produces media. This actor owns
/// the backend-facing session lifecycle, realtime media messages, local rewind
/// frame window, and out-of-band commit uploads.
actor CaptureStreamEndpoint {
    let events: AsyncStream<RewindProtocolEvent>

    private let configuration: RewindConfiguration
    private let client: RewindProtocolClient
    private let frameBuffer: RollingFrameBuffer
    private let frameCache: CaptureFrameCache
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vogelhaus.Rewind",
        category: "CaptureStreamEndpoint"
    )

    private var activeSessionID: UUID?
    private var activeSession: CaptureStreamSession?
    private var connectTask: Task<Void, Never>?

    init(
        configuration: RewindConfiguration = .defaultConfiguration,
        client: RewindProtocolClient? = nil,
        frameBuffer: RollingFrameBuffer = RollingFrameBuffer(
            maximumFrames: 140,
            maximumAge: 20
        ),
        frameCache: CaptureFrameCache = .shared
    ) {
        self.configuration = configuration
        self.client = client ?? RewindProtocolClient(configuration: configuration)
        self.frameBuffer = frameBuffer
        self.frameCache = frameCache
        self.events = self.client.events
    }

    func startSession(_ session: CaptureStreamSession) async {
        activeSessionID = session.id
        activeSession = session
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            await self?.connect(session)
        }
    }

    func reconnectActiveSession() async {
        guard let activeSession else {
            return
        }

        connectTask?.cancel()
        connectTask = Task { [weak self] in
            await self?.connect(activeSession)
        }
    }

    private func connect(_ session: CaptureStreamSession) async {
        guard !Task.isCancelled else {
            return
        }

        let hello = RewindSessionHello(
            device: RewindSessionHello.Device(
                id: configuration.deviceID,
                kind: "ios"
            ),
            buffers: RewindSessionHello.Buffers(
                rewind: RewindSessionHello.Buffers.Rewind(
                    durationMs: session.rewindBufferDurationMilliseconds,
                    frameIntervalMs: session.deviceFrameIntervalMilliseconds,
                    maxFrames: session.rewindBufferMaximumFrames
                )
            ),
            context: .current()
        )

        do {
            try await client.connect(hello: hello)
            guard activeSessionID == session.id else {
                await client.disconnect()
                return
            }

            logger.info("Started Rewind capture protocol session \(session.id.uuidString, privacy: .public)")
        } catch {
            guard !Task.isCancelled, activeSessionID == session.id else {
                return
            }

            await client.reportFailure(error.localizedDescription, scope: .connection)
            logger.error("Failed to connect Rewind protocol session: \(error.localizedDescription, privacy: .public)")
        }
    }

    func receiveVideoFrame(_ frame: CaptureVideoFrame) async {
        guard activeSessionID == frame.sessionID else {
            logger.error("Dropped video frame for inactive capture session \(frame.sessionID.uuidString, privacy: .public)")
            return
        }

        await frameBuffer.append(frame.bufferedFrame)

        do {
            try await client.sendImageFrame(frame.bufferedFrame)
        } catch {
            logger.error("Failed to stream image frame: \(error.localizedDescription, privacy: .public)")
        }
    }

    func receiveAudioChunk(_ chunk: CaptureAudioChunk) async {
        guard activeSessionID == chunk.sessionID else {
            logger.error("Dropped audio chunk for inactive capture session \(chunk.sessionID.uuidString, privacy: .public)")
            return
        }

        do {
            try await client.sendAudioChunk(chunk)
        } catch {
            logger.error("Failed to stream audio chunk: \(error.localizedDescription, privacy: .public)")
        }
    }

    func finishSession(id: UUID) async {
        guard activeSessionID == id else {
            logger.error("Ignored finish for inactive capture session \(id.uuidString, privacy: .public)")
            return
        }

        activeSessionID = nil
        activeSession = nil
        connectTask?.cancel()
        connectTask = nil
        await frameBuffer.removeAll()
        await client.disconnect()
        logger.info("Finished Rewind capture protocol session \(id.uuidString, privacy: .public)")
    }

    func commit(_ request: RewindSaveRequest, location: RewindCapturedLocation?) async {
        let window = captureWindow(for: request)
        await waitForCaptureWindowIfNeeded(window)
        let frames = await frameBuffer.selectFrames(window: window)

        do {
            _ = try await client.commit(
                saveRequest: request,
                window: window,
                frames: frames,
                location: location
            )
            await persistSavedMemoryFrames(frames, eventID: request.eventID, sessionID: activeSessionID)
        } catch {
            await client.reportFailure(error.localizedDescription)
            logger.error("Failed to commit rewind frames: \(error.localizedDescription, privacy: .public)")
        }
    }

    func search(query: String) async {
        do {
            try await client.search(query: query)
        } catch {
            await client.reportFailure(error.localizedDescription)
            logger.error("Failed to search rewinds: \(error.localizedDescription, privacy: .public)")
        }
    }

    func sendText(_ text: String) async {
        do {
            try await client.sendText(text)
        } catch {
            await client.reportFailure(error.localizedDescription)
            logger.error("Failed to send text prompt: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func captureWindow(for request: RewindSaveRequest) -> RewindCaptureWindow {
        let anchor = Self.date(from: request.captureAnchorUTC)
            ?? Self.date(from: request.captureWindowEndedAt)
            ?? Date()
        let startedAt = anchor.addingTimeInterval(-Self.savedMemoryPreRoll)
        let endedAt = anchor.addingTimeInterval(Self.savedMemoryPostRoll)
        let durationMs = Int((Self.savedMemoryPreRoll + Self.savedMemoryPostRoll) * 1_000)
        let frameIntervalMilliseconds = activeSession?.deviceFrameIntervalMilliseconds ?? 1_000

        return RewindCaptureWindow(
            anchorUTC: ISO8601DateFormatter.rewindProtocol.string(from: anchor),
            durationMs: durationMs,
            startedAt: startedAt,
            endedAt: endedAt,
            startedAtUTC: ISO8601DateFormatter.rewindProtocol.string(from: startedAt),
            endedAtUTC: ISO8601DateFormatter.rewindProtocol.string(from: endedAt),
            frameInterval: TimeInterval(frameIntervalMilliseconds) / 1_000
        )
    }

    private func waitForCaptureWindowIfNeeded(_ window: RewindCaptureWindow) async {
        let remainingDuration = window.endedAt.timeIntervalSince(Date())
        guard remainingDuration > 0 else {
            return
        }

        do {
            try await Task.sleep(for: .seconds(remainingDuration))
        } catch {}
    }

    private func persistSavedMemoryFrames(_ frames: [RewindBufferedFrame], eventID: String, sessionID: UUID?) async {
        guard let sessionID, !frames.isEmpty else {
            return
        }

        let deviceFrames = frames.enumerated().map { index, frame in
            DeviceCaptureFrame(
                deviceFrameUUID: frame.id,
                memoryEventID: eventID,
                sessionID: sessionID,
                sequenceNumber: index + 1,
                timestamp: frame.capturedAt,
                width: frame.width,
                height: frame.height,
                data: frame.jpegData,
                fileExtension: "jpg"
            )
        }

        _ = await frameCache.storeMemoryFrames(deviceFrames)
    }

    private nonisolated static func date(from value: String?) -> Date? {
        value.flatMap { ISO8601DateFormatter.rewindProtocol.date(from: $0) }
    }

    private static let savedMemoryPreRoll: TimeInterval = 5
    private static let savedMemoryPostRoll: TimeInterval = 5
}

/// Metadata for a single capture stream session.
struct CaptureStreamSession: Sendable {
    let id: UUID
    let startedAt: Date
    let captureFrameRate: Int
    let streamFrameRate: Int
    let streamLongestEdge: Int
    let streamJPEGQuality: Double
    let source: CaptureSource
    let rewindBufferDurationMilliseconds: Int
    let rewindBufferMaximumFrames: Int
    let deviceFrameIntervalMilliseconds: Int
    let realtimeImageIntervalMilliseconds: Int
    let audioChunkMilliseconds: Int
    let audioSampleRate: Int
}

/// The capture source backing a stream session.
enum CaptureSource: String, Sendable {
    case phone
}

/// A server-ready video frame produced from the higher-quality capture feed.
struct CaptureVideoFrame: Sendable {
    let sessionID: UUID
    let deviceFrameUUID: String
    let sequenceNumber: Int
    let timestamp: Date
    let width: Int
    let height: Int
    let jpegQuality: Double
    let data: Data

    var bufferedFrame: RewindBufferedFrame {
        RewindBufferedFrame(
            id: deviceFrameUUID,
            capturedAt: timestamp,
            width: width,
            height: height,
            jpegData: data
        )
    }
}

/// A PCM audio chunk produced by capture mode.
struct CaptureAudioChunk: Sendable {
    let sessionID: UUID
    let sequenceNumber: Int
    let timestamp: Date
    let duration: TimeInterval
    let sampleCount: Int
    let mimeType: String
    let data: Data
}
