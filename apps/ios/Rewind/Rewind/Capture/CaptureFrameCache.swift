//
//  CaptureFrameCache.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

import Foundation
import OSLog

/// Persists one frame per captured second for the on-device day timeline.
///
/// The cache writes timestamped HEIC frames under Library/Caches so the system may
/// reclaim storage if needed. `CaptureTimelineStore` reads the indexed frames and
/// turns them into the dynamic scrubber range shown by `Today`.
actor CaptureFrameCache {
    static let shared = CaptureFrameCache()

    private let rootDirectory: URL
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vogelhaus.Rewind",
        category: "CaptureFrameCache"
    )

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureFrames", isDirectory: true)
    }

    /// Writes a frame if that capture second is not already present.
    ///
    /// Multiple capture sources can race into the same second when capture is restarted.
    /// The timestamp index remains the source of truth and keeps one local frame per
    /// second so scrubber lookup stays predictable.
    @discardableResult
    func storeFrame(_ frame: DeviceCaptureFrame) async -> CachedCaptureFrame? {
        let dayDirectory = rootDirectory.appendingPathComponent(Self.dayIdentifier(for: frame.timestamp), isDirectory: true)
        let indexURL = dayDirectory.appendingPathComponent("index.json")

        do {
            try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)

            var index = try loadIndex(from: indexURL)
            let captureSecond = Self.captureSecond(for: frame.timestamp)
            if let existingFrame = index.frames.first(where: { $0.captureSecond == captureSecond }) {
                return CachedCaptureFrame(indexFrame: existingFrame, dayDirectory: dayDirectory)
            }

            let fileName = "\(captureSecond)-\(frame.sequenceNumber).heic"
            let fileURL = dayDirectory.appendingPathComponent(fileName)
            try frame.data.write(to: fileURL, options: .atomic)

            let indexFrame = CachedCaptureFrame.IndexFrame(
                deviceFrameUUID: frame.deviceFrameUUID,
                sessionID: frame.sessionID,
                sequenceNumber: frame.sequenceNumber,
                timestamp: frame.timestamp,
                captureSecond: captureSecond,
                width: frame.width,
                height: frame.height,
                byteCount: frame.data.count,
                relativePath: fileName
            )

            index.frames.append(indexFrame)
            index.frames.sort { $0.timestamp < $1.timestamp }
            try saveIndex(index, to: indexURL)

            logger.info("Stored cached capture frame \(fileName, privacy: .public)")
            return CachedCaptureFrame(indexFrame: indexFrame, dayDirectory: dayDirectory)
        } catch {
            logger.error("Failed to store cached capture frame: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Loads all cached frames whose day folder matches the supplied date.
    func frames(forDayContaining date: Date) async -> [CachedCaptureFrame] {
        let dayDirectory = rootDirectory.appendingPathComponent(Self.dayIdentifier(for: date), isDirectory: true)
        let indexURL = dayDirectory.appendingPathComponent("index.json")

        do {
            let index = try loadIndex(from: indexURL)
            return index.frames
                .sorted { $0.timestamp < $1.timestamp }
                .map { CachedCaptureFrame(indexFrame: $0, dayDirectory: dayDirectory) }
                .filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            logger.error("Failed to load cached capture frames: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Finds the cached phone frame closest to a timestamp.
    ///
    /// Backend search results can reference server-side frame rows that are not
    /// the same images persisted in the phone cache. Timestamp proximity is the
    /// stable join point for selecting the local image to display.
    func nearestFrame(near date: Date, maximumDistance: TimeInterval) async -> CachedCaptureFrame? {
        let match = await nearestFrameMatch(near: date)

        guard match.distance <= maximumDistance else {
            return nil
        }

        return match.frame
    }

    /// Returns the local frame window around the cached frame nearest to a timestamp.
    ///
    /// Search result thumbnails use this instead of a single nearest image because
    /// one frame may not represent the memory well. The returned frames are sorted
    /// chronologically and include up to `frameCount` frames on each side.
    func frameWindow(
        near date: Date,
        frameCountBeforeAndAfter: Int,
        maximumDistance: TimeInterval
    ) async -> [CachedCaptureFrame] {
        let frames = await framesSurrounding(date)
        guard !frames.isEmpty else {
            return []
        }

        var nearestFrameIndex = 0
        var nearestDistance = abs(frames[0].timestamp.timeIntervalSince(date))

        for frameIndex in frames.indices.dropFirst() {
            let distance = abs(frames[frameIndex].timestamp.timeIntervalSince(date))
            if distance < nearestDistance {
                nearestDistance = distance
                nearestFrameIndex = frameIndex
            }
        }

        guard nearestDistance <= maximumDistance else {
            return []
        }

        let lowerBound = max(frames.startIndex, nearestFrameIndex - frameCountBeforeAndAfter)
        let upperBound = min(frames.index(before: frames.endIndex), nearestFrameIndex + frameCountBeforeAndAfter)
        return Array(frames[lowerBound...upperBound])
    }

    private func nearestFrameMatch(near date: Date) async -> (frame: CachedCaptureFrame?, distance: TimeInterval) {
        var bestMatch: CachedCaptureFrame?
        var bestDistance = TimeInterval.greatestFiniteMagnitude

        for frame in await framesSurrounding(date) {
            let distance = abs(frame.timestamp.timeIntervalSince(date))
            if distance < bestDistance {
                bestDistance = distance
                bestMatch = frame
            }
        }

        return (bestMatch, bestDistance)
    }

    private func framesSurrounding(_ date: Date) async -> [CachedCaptureFrame] {
        let daysToSearch = [
            date.addingTimeInterval(-24 * 60 * 60),
            date,
            date.addingTimeInterval(24 * 60 * 60)
        ]

        var surroundingFrames: [CachedCaptureFrame] = []
        for day in daysToSearch {
            surroundingFrames.append(contentsOf: await frames(forDayContaining: day))
        }

        return surroundingFrames.sorted { $0.timestamp < $1.timestamp }
    }

    private func loadIndex(from url: URL) throws -> CaptureFrameIndex {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CaptureFrameIndex(frames: [])
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CaptureFrameIndex.self, from: data)
    }

    private func saveIndex(_ index: CaptureFrameIndex, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: url, options: .atomic)
    }

    private static func captureSecond(for date: Date) -> Int {
        Int(date.timeIntervalSince1970.rounded(.down))
    }

    private static func dayIdentifier(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0

        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// A 720p HEIC frame ready for on-device persistence.
nonisolated struct DeviceCaptureFrame: Sendable {
    let deviceFrameUUID: String
    let sessionID: UUID
    let sequenceNumber: Int
    let timestamp: Date
    let width: Int
    let height: Int
    let data: Data
}

/// A cached frame available to the timeline UI.
nonisolated struct CachedCaptureFrame: Identifiable, Hashable, Sendable {
    let deviceFrameUUID: String?
    let sessionID: UUID
    let sequenceNumber: Int
    let timestamp: Date
    let captureSecond: Int
    let width: Int
    let height: Int
    let byteCount: Int
    let fileURL: URL

    var id: String {
        deviceFrameUUID ?? "\(captureSecond)-\(sequenceNumber)"
    }
}

private nonisolated struct CaptureFrameIndex: Codable {
    var frames: [CachedCaptureFrame.IndexFrame]
}

private extension CachedCaptureFrame {
    nonisolated struct IndexFrame: Codable {
        let deviceFrameUUID: String?
        let sessionID: UUID
        let sequenceNumber: Int
        let timestamp: Date
        let captureSecond: Int
        let width: Int
        let height: Int
        let byteCount: Int
        let relativePath: String
    }

    nonisolated init(indexFrame: IndexFrame, dayDirectory: URL) {
        self.deviceFrameUUID = indexFrame.deviceFrameUUID
        self.sessionID = indexFrame.sessionID
        self.sequenceNumber = indexFrame.sequenceNumber
        self.timestamp = indexFrame.timestamp
        self.captureSecond = indexFrame.captureSecond
        self.width = indexFrame.width
        self.height = indexFrame.height
        self.byteCount = indexFrame.byteCount
        self.fileURL = dayDirectory.appendingPathComponent(indexFrame.relativePath)
    }
}
