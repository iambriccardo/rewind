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
/// day of cached frames, exposes day bounds plus recorded intervals, and resolves
/// the nearest available frame for the selected time.
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
        visibleRange = Self.makeVisibleRange(from: cachedFrames, containing: date, calendar: calendar)
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

    /// Resolves the frame shown while the user browses the timeline.
    ///
    /// A timestamp inside a recorded interval uses the nearest frame. A timestamp
    /// in a recording gap snaps forward to the next available interval so the UI
    /// does not hold on a stale previous frame while crossing empty time.
    func timelineFrame(for date: Date) -> CachedCaptureFrame? {
        guard !frames.isEmpty else {
            return nil
        }

        return nearestFrame(to: timelineSelectionDate(for: date))
    }

    /// Returns the nearest selectable timestamp for timeline browsing.
    ///
    /// Gaps snap forward to the next recorded interval so browsing empty time does
    /// not hold on the last frame. After the final interval, the selection falls
    /// back to the last recorded boundary.
    func timelineSelectionDate(for date: Date) -> Date {
        if Self.isNow(date) {
            return .now
        }

        if availableIntervals.isEmpty || availableIntervals.contains(where: { $0.contains(date) }) {
            return date
        }

        if let nextInterval = availableIntervals.first(where: { $0.start > date }) {
            return nextInterval.start
        }

        if let previousInterval = availableIntervals.last(where: { $0.end < date }) {
            return previousInterval.end
        }

        return date
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

    /// Uses the loaded day as the scrubber bounds; `Scrubber` uses
    /// `availableIntervals` to stitch recorded segments together visually.
    private static func makeVisibleRange(
        from frames: [CachedCaptureFrame],
        containing date: Date,
        calendar: Calendar
    ) -> DateInterval? {
        guard !frames.isEmpty else {
            return nil
        }

        let dayStart = calendar.startOfDay(for: date)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let dayEnd = calendar.isDate(Date.now, inSameDayAs: dayStart) ? min(Date.now, nextDay) : nextDay

        return DateInterval(start: dayStart, end: max(dayStart.addingTimeInterval(1), dayEnd))
    }

    private static let maximumContiguousFrameGap: TimeInterval = 2.5
    private static let nowSelectionTolerance: TimeInterval = 60

    private static func isNow(_ date: Date) -> Bool {
        abs(date.timeIntervalSince(.now)) <= nowSelectionTolerance
    }
}
