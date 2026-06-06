//
//  CaptureStreamEndpoint.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

import Foundation
import OSLog

/// Receives phone capture stream events in the same shape a backend uploader will consume later.
///
/// The current implementation intentionally does not upload or persist anything. It gives the
/// phone capture flow a stable boundary for session lifecycle, video frame, and audio chunk events.
actor CaptureStreamEndpoint {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vogelhaus.Rewind",
        category: "CaptureStreamEndpoint"
    )

    private var activeSessionID: UUID?

    func startSession(_ session: CaptureStreamSession) {
        activeSessionID = session.id
        logger.info("Started capture stream session \(session.id.uuidString, privacy: .public)")
    }

    func receiveVideoFrame(_ frame: CaptureVideoFrame) {
        guard activeSessionID == frame.sessionID else {
            logger.error("Dropped video frame for inactive capture session \(frame.sessionID.uuidString, privacy: .public)")
            return
        }
    }

    func receiveAudioChunk(_ chunk: CaptureAudioChunk) {
        guard activeSessionID == chunk.sessionID else {
            logger.error("Dropped audio chunk for inactive capture session \(chunk.sessionID.uuidString, privacy: .public)")
            return
        }
    }

    func finishSession(id: UUID) {
        guard activeSessionID == id else {
            logger.error("Ignored finish for inactive capture session \(id.uuidString, privacy: .public)")
            return
        }

        activeSessionID = nil
        logger.info("Finished capture stream session \(id.uuidString, privacy: .public)")
    }
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
}

/// The capture source backing a stream session.
enum CaptureSource: String, Sendable {
    case phone
}

/// A server-ready video frame produced from the higher-quality capture feed.
struct CaptureVideoFrame: Sendable {
    let sessionID: UUID
    let sequenceNumber: Int
    let timestamp: Date
    let width: Int
    let height: Int
    let jpegQuality: Double
    let data: Data
}

/// An audio sample chunk produced by capture mode.
struct CaptureAudioChunk: Sendable {
    let sessionID: UUID
    let sequenceNumber: Int
    let timestamp: Date
    let duration: TimeInterval
    let sampleCount: Int
}
