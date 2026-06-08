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

    /// Summarizes the on-device image cache without loading image bytes.
    func cacheSummary() async -> CaptureFrameCacheSummary {
        do {
            return try makeCacheSummary()
        } catch {
            logger.error("Failed to summarize cached capture frames: \(error.localizedDescription, privacy: .public)")
            return .empty
        }
    }

    /// Deletes all on-device cached capture images and index files.
    ///
    /// This only clears local `Library/Caches/CaptureFrames` storage. It does not
    /// delete committed backend memory metadata or stop an active capture session
    /// from writing new frames after the deletion completes.
    @discardableResult
    func deleteAllFrames() async throws -> CaptureFrameCacheSummary {
        let summary = try makeCacheSummary()

        guard FileManager.default.fileExists(atPath: rootDirectory.path) else {
            return summary
        }

        do {
            try FileManager.default.removeItem(at: rootDirectory)
            logger.info(
                "Deleted \(summary.imageCount, privacy: .public) cached capture images totaling \(summary.byteCount, privacy: .public) bytes"
            )
            return summary
        } catch {
            logger.error("Failed to delete cached capture frames: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Writes a local timeline frame for every accepted device-cache sample.
    ///
    /// The timestamp index remains the source of truth. Multiple frames can share
    /// the same integer capture second so search result cards can play back the
    /// highest local frame rate retained on device.
    @discardableResult
    func storeFrame(_ frame: DeviceCaptureFrame) async -> CachedCaptureFrame? {
        await storeTimelineFrame(frame)
    }

    /// Persists a dense saved-memory frame window.
    ///
    /// Saved memories keep each buffered server-facing frame by UUID so commit
    /// uploads can retain their exact frame references.
    @discardableResult
    func storeMemoryFrames(_ frames: [DeviceCaptureFrame]) async -> [CachedCaptureFrame] {
        var cachedFrames: [CachedCaptureFrame] = []

        for frame in frames {
            if let cachedFrame = await storeDenseMemoryFrame(frame) {
                cachedFrames.append(cachedFrame)
            }
        }

        if let memoryEventID = frames.first?.memoryEventID {
            logger.info("Stored \(cachedFrames.count, privacy: .public) saved memory frames for event \(memoryEventID, privacy: .public)")
        }

        return cachedFrames
    }

    private func storeTimelineFrame(_ frame: DeviceCaptureFrame) async -> CachedCaptureFrame? {
        let dayDirectory = rootDirectory.appendingPathComponent(Self.dayIdentifier(for: frame.timestamp), isDirectory: true)
        let indexURL = dayDirectory.appendingPathComponent("index.json")

        do {
            try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)

            var index = try loadIndex(from: indexURL)
            let captureSecond = Self.captureSecond(for: frame.timestamp)
            let fileName = "\(captureSecond)-\(frame.sequenceNumber)-\(frame.deviceFrameUUID).\(frame.fileExtension)"
            let fileURL = dayDirectory.appendingPathComponent(fileName)
            try frame.data.write(to: fileURL, options: .atomic)

            let indexFrame = CachedCaptureFrame.IndexFrame(
                deviceFrameUUID: frame.deviceFrameUUID,
                memoryEventID: frame.memoryEventID,
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

    private func storeDenseMemoryFrame(_ frame: DeviceCaptureFrame) async -> CachedCaptureFrame? {
        let dayDirectory = rootDirectory.appendingPathComponent(Self.dayIdentifier(for: frame.timestamp), isDirectory: true)
        let indexURL = dayDirectory.appendingPathComponent("index.json")

        do {
            try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)

            var index = try loadIndex(from: indexURL)

            let captureSecond = Self.captureSecond(for: frame.timestamp)
            let fileName = "\(captureSecond)-\(frame.sequenceNumber)-\(frame.deviceFrameUUID).\(frame.fileExtension)"
            let fileURL = dayDirectory.appendingPathComponent(fileName)
            try frame.data.write(to: fileURL, options: .atomic)

            let indexFrame = CachedCaptureFrame.IndexFrame(
                deviceFrameUUID: frame.deviceFrameUUID,
                memoryEventID: frame.memoryEventID,
                sessionID: frame.sessionID,
                sequenceNumber: frame.sequenceNumber,
                timestamp: frame.timestamp,
                captureSecond: captureSecond,
                width: frame.width,
                height: frame.height,
                byteCount: frame.data.count,
                relativePath: fileName
            )

            if let existingFrameIndex = index.frames.firstIndex(where: { $0.deviceFrameUUID == frame.deviceFrameUUID }) {
                index.frames[existingFrameIndex] = indexFrame
            } else {
                index.frames.append(indexFrame)
            }
            index.frames.sort { $0.timestamp < $1.timestamp }
            try saveIndex(index, to: indexURL)

            return CachedCaptureFrame(indexFrame: indexFrame, dayDirectory: dayDirectory)
        } catch {
            logger.error("Failed to store saved memory frame: \(error.localizedDescription, privacy: .public)")
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

    /// Loads the newest cached frame available across all local capture days.
    ///
    /// The Today screen uses this to start from the most recent known capture
    /// instead of assuming the current clock time has a frame available.
    func latestFrame() async -> CachedCaptureFrame? {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else {
            return nil
        }

        do {
            let dayDirectories = try FileManager.default.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            var latestFrame: CachedCaptureFrame?
            for dayDirectory in dayDirectories {
                let resourceValues = try dayDirectory.resourceValues(forKeys: [.isDirectoryKey])
                guard resourceValues.isDirectory == true else {
                    continue
                }

                let indexURL = dayDirectory.appendingPathComponent("index.json")
                let index = try loadIndex(from: indexURL)
                for indexFrame in index.frames {
                    let cachedFrame = CachedCaptureFrame(indexFrame: indexFrame, dayDirectory: dayDirectory)
                    guard FileManager.default.fileExists(atPath: cachedFrame.fileURL.path) else {
                        continue
                    }

                    if let currentLatestFrame = latestFrame {
                        if cachedFrame.timestamp > currentLatestFrame.timestamp {
                            latestFrame = cachedFrame
                        }
                    } else {
                        latestFrame = cachedFrame
                    }
                }
            }

            return latestFrame
        } catch {
            logger.error("Failed to load latest cached capture frame: \(error.localizedDescription, privacy: .public)")
            return nil
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
        return frameWindow(
            near: date,
            frameCountBeforeAndAfter: frameCountBeforeAndAfter,
            maximumDistance: maximumDistance,
            frames: frames
        )
    }

    /// Returns the high-quality local timeline frame window nearest to a timestamp.
    ///
    /// Search result cards intentionally avoid backend-retained frame references
    /// and dense committed JPG frames. Those server-facing frames are lower quality
    /// and are expected to go away; the local HEIC timeline cache is the stable
    /// source for result imagery.
    func localTimelineFrameWindow(
        near date: Date,
        frameCountBeforeAndAfter: Int,
        maximumDistance: TimeInterval
    ) async -> [CachedCaptureFrame] {
        let surroundingFrames = await framesSurrounding(date)
        let localTimelineFrames = surroundingFrames
            .filter { $0.memoryEventID == nil }

        return frameWindow(
            near: date,
            frameCountBeforeAndAfter: frameCountBeforeAndAfter,
            maximumDistance: maximumDistance,
            frames: localTimelineFrames
        )
    }

    private func frameWindow(
        near date: Date,
        frameCountBeforeAndAfter: Int,
        maximumDistance: TimeInterval,
        frames: [CachedCaptureFrame]
    ) -> [CachedCaptureFrame] {
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

    /// Loads dense local frames explicitly persisted for a saved memory.
    func memoryFrames(eventID: String, near date: Date) async -> [CachedCaptureFrame] {
        let frames = await framesSurrounding(date)
        return frames
            .filter { $0.memoryEventID == eventID }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Loads local frames whose device UUIDs match backend frame references.
    ///
    /// This keeps memories saved before local event tagging visually connected
    /// as long as the backend has committed frame references for the event.
    func frames(matchingDeviceFrameUUIDs deviceFrameUUIDs: [String], near date: Date) async -> [CachedCaptureFrame] {
        guard !deviceFrameUUIDs.isEmpty else {
            return []
        }

        var framesByDeviceFrameUUID: [String: CachedCaptureFrame] = [:]
        for frame in await framesSurrounding(date) {
            guard let deviceFrameUUID = frame.deviceFrameUUID else {
                continue
            }

            framesByDeviceFrameUUID[deviceFrameUUID] = frame
        }

        return deviceFrameUUIDs.compactMap { framesByDeviceFrameUUID[$0] }
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

    private func makeCacheSummary() throws -> CaptureFrameCacheSummary {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else {
            return .empty
        }

        var imageCount = 0
        var byteCount: Int64 = 0
        var dayCount = 0

        let dayDirectories = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for dayDirectory in dayDirectories {
            let resourceValues = try dayDirectory.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues.isDirectory == true else {
                continue
            }

            dayCount += 1

            guard let enumerator = FileManager.default.enumerator(
                at: dayDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                let fileValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard fileValues.isRegularFile == true, fileURL.lastPathComponent != "index.json" else {
                    continue
                }

                imageCount += 1
                byteCount += Int64(fileValues.fileSize ?? 0)
            }
        }

        return CaptureFrameCacheSummary(imageCount: imageCount, byteCount: byteCount, dayCount: dayCount)
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

/// Aggregate storage information for on-device cached capture images.
nonisolated struct CaptureFrameCacheSummary: Equatable, Sendable {
    let imageCount: Int
    let byteCount: Int64
    let dayCount: Int

    var isEmpty: Bool {
        imageCount == 0
    }

    static let empty = CaptureFrameCacheSummary(imageCount: 0, byteCount: 0, dayCount: 0)
}

/// A 720p HEIC frame ready for on-device persistence.
nonisolated struct DeviceCaptureFrame: Sendable {
    let deviceFrameUUID: String
    let memoryEventID: String?
    let sessionID: UUID
    let sequenceNumber: Int
    let timestamp: Date
    let width: Int
    let height: Int
    let data: Data
    let fileExtension: String
}

/// A cached frame available to the timeline UI.
nonisolated struct CachedCaptureFrame: Identifiable, Hashable, Sendable {
    let deviceFrameUUID: String?
    let memoryEventID: String?
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
        let memoryEventID: String?
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
        self.memoryEventID = indexFrame.memoryEventID
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
