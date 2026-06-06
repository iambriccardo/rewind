//
//  CaptureTimelineStore.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

import Foundation
import Observation

/// UI-facing adapter for cached capture frames shown on the Today timeline.
///
/// The store keeps SwiftUI isolated from cache persistence details. It loads one
/// day of cached frames, derives the scrubber's dynamic range from real capture
/// timestamps, and exposes nearest-frame lookup for the selected time.
@MainActor
@Observable
final class CaptureTimelineStore {
    private(set) var frames: [CachedCaptureFrame] = []
    private(set) var availableIntervals: [DateInterval] = []
    private(set) var visibleRange: DateInterval?
    private(set) var loadedDay: Date?
    private(set) var isLoading = false

    @ObservationIgnored private let cache: CaptureFrameCache
    @ObservationIgnored private let calendar: Calendar

    init(cache: CaptureFrameCache = .shared, calendar: Calendar = .current) {
        self.cache = cache
        self.calendar = calendar
    }

    func loadDay(containing date: Date) async {
        isLoading = true
        defer {
            isLoading = false
        }

        let cachedFrames = await cache.frames(forDayContaining: date)
        frames = cachedFrames
        availableIntervals = Self.makeAvailableIntervals(from: cachedFrames)
        visibleRange = Self.makeVisibleRange(from: cachedFrames)
        loadedDay = calendar.startOfDay(for: date)
    }

    func nearestFrame(to date: Date) -> CachedCaptureFrame? {
        guard !frames.isEmpty else {
            return nil
        }

        var nearestFrame = frames[0]
        var nearestDistance = abs(frames[0].timestamp.timeIntervalSince(date))

        for frame in frames.dropFirst() {
            let distance = abs(frame.timestamp.timeIntervalSince(date))
            if distance < nearestDistance {
                nearestFrame = frame
                nearestDistance = distance
            }
        }

        return nearestFrame
    }

    func initialSelection(preferredDate: Date = .now) -> Date {
        if let nearestFrame = nearestFrame(to: preferredDate) {
            return nearestFrame.timestamp
        }

        return preferredDate
    }

    private static func makeAvailableIntervals(from frames: [CachedCaptureFrame]) -> [DateInterval] {
        guard let firstFrame = frames.first else {
            return []
        }

        var intervals: [DateInterval] = []
        var intervalStart = firstFrame.timestamp
        var previousDate = firstFrame.timestamp

        for frame in frames.dropFirst() {
            let gap = frame.timestamp.timeIntervalSince(previousDate)
            if gap > maximumContiguousFrameGap {
                intervals.append(DateInterval(start: intervalStart, end: previousDate.addingTimeInterval(1)))
                intervalStart = frame.timestamp
            }

            previousDate = frame.timestamp
        }

        intervals.append(DateInterval(start: intervalStart, end: previousDate.addingTimeInterval(1)))
        return intervals
    }

    private static func makeVisibleRange(from frames: [CachedCaptureFrame]) -> DateInterval? {
        guard let firstFrame = frames.first, let lastFrame = frames.last else {
            return nil
        }

        let capturedStart = firstFrame.timestamp
        let capturedEnd = lastFrame.timestamp.addingTimeInterval(1)
        let capturedDuration = max(1, capturedEnd.timeIntervalSince(capturedStart))
        let baseDuration = max(minimumVisibleDuration, capturedDuration)
        let edgeBuffer = min(max(baseDuration * visibleRangeBufferFraction, minimumVisibleRangeBuffer), maximumVisibleRangeBuffer)

        var visibleStart = capturedStart.addingTimeInterval(-edgeBuffer)
        var visibleEnd = capturedEnd.addingTimeInterval(edgeBuffer)
        let visibleDuration = visibleEnd.timeIntervalSince(visibleStart)
        if visibleDuration < minimumVisibleDuration {
            let extraPadding = (minimumVisibleDuration - visibleDuration) / 2
            visibleStart = visibleStart.addingTimeInterval(-extraPadding)
            visibleEnd = visibleEnd.addingTimeInterval(extraPadding)
        }

        return DateInterval(start: visibleStart, end: visibleEnd)
    }

    private static let maximumContiguousFrameGap: TimeInterval = 2.5
    private static let minimumVisibleDuration: TimeInterval = 60
    private static let visibleRangeBufferFraction: TimeInterval = 0.12
    private static let minimumVisibleRangeBuffer: TimeInterval = 8
    private static let maximumVisibleRangeBuffer: TimeInterval = 15 * 60
}
