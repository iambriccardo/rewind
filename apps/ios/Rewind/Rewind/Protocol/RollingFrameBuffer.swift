//
//  RollingFrameBuffer.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

import Foundation
import OSLog

/// Keeps the client-side rewind frame window keyed by backend-visible frame UUIDs.
///
/// The live socket only receives downsampled realtime JPEGs. Rewind commits use this
/// same buffer to attach stable frame references, and optionally raw JPEG bytes, when
/// the backend asks for a specific rewind duration.
actor RollingFrameBuffer {
    private var frames: [RewindBufferedFrame] = []
    private let maximumFrames: Int
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vogelhaus.Rewind",
        category: "RollingFrameBuffer"
    )

    init(maximumFrames: Int = 60) {
        self.maximumFrames = maximumFrames
    }

    func append(_ frame: RewindBufferedFrame) {
        frames.append(frame)
        if frames.count > maximumFrames {
            frames.removeFirst(frames.count - maximumFrames)
        }
    }

    func selectFrames(duration: TimeInterval) -> [RewindBufferedFrame] {
        guard let lastFrame = frames.last else {
            return []
        }

        let cutoff = lastFrame.capturedAt.addingTimeInterval(-max(1, duration))
        let selectedFrames = frames.filter { $0.capturedAt >= cutoff }
        if selectedFrames.isEmpty {
            logger.error("Falling back to one frame because rewind selection was empty")
            return [lastFrame]
        }

        return selectedFrames
    }

    func selectFrames(window: RewindCaptureWindow) -> [RewindBufferedFrame] {
        let selectedFrames = frames.filter { frame in
            frame.capturedAt >= window.startedAt && frame.capturedAt <= window.endedAt
        }
        if selectedFrames.isEmpty {
            let tolerance = max(2, window.frameInterval * 2)
            let fallbackStartedAt = window.startedAt.addingTimeInterval(-tolerance)
            if let nearestPastFrame = frames.reversed().first(where: { frame in
                frame.capturedAt <= window.endedAt && frame.capturedAt >= fallbackStartedAt
            }) {
                logger.error("Falling back to nearest frame because rewind window selection was empty")
                return [nearestPastFrame]
            }
        }

        return selectedFrames
    }

    func removeAll() {
        frames.removeAll()
    }
}

struct RewindBufferedFrame: Identifiable, Sendable {
    let id: String
    let capturedAt: Date
    let width: Int
    let height: Int
    let jpegData: Data
}

struct RewindCaptureWindow: Sendable {
    let anchorUTC: String
    let durationMs: Int
    let startedAt: Date
    let endedAt: Date
    let startedAtUTC: String
    let endedAtUTC: String
    let frameInterval: TimeInterval
}
