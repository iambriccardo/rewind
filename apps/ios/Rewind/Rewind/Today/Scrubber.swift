//
//  Scrubber.swift
//  Rewind
//
//  Created by Florian Schulte on 6/6/26.
//

import SwiftUI

/// A right-edge day scrubber that maps a date range onto a vertical timeline.
///
/// `Scrubber` keeps range ownership outside the view so parent screens can set
/// the visible day window while the control owns drag mapping, live-current-time
/// tracking, and visual thumb feedback.
struct Scrubber: View {
    @Binding private var selection: Date
    @Binding private var externalIsScrubbing: Bool

    private let startDate: Date
    private let endDate: Date
    private let availableIntervals: [DateInterval]
    private let calendar: Calendar
    private let protectedVerticalInsets: EdgeInsets
    private let timelineScale: TimelineScale
    private let timelineLayout: TimelineLayout

    @State private var feedbackStep: Int
    @State private var selectionFollowsCurrentTime: Bool
    @State private var currentDate = Date.now
    @State private var scrubInteractionFeedbackID = 0
    @State private var isDragActive = false
    // During drag, the thumb follows the stitched recording-time position while
    // the bound selection still resolves to a real timestamp.
    @State private var visualScrubDate: Date?
    @GestureState private var isScrubbing = false

    init(
        selection: Binding<Date>,
        isScrubbing: Binding<Bool> = .constant(false),
        startDate: Date,
        endDate: Date,
        availableIntervals: [DateInterval] = [],
        protectedVerticalInsets: EdgeInsets = EdgeInsets(),
        calendar: Calendar = .current
    ) {
        self._selection = selection
        self._externalIsScrubbing = isScrubbing
        self.startDate = startDate
        self.endDate = endDate
        self.availableIntervals = availableIntervals
        self.calendar = calendar
        self.protectedVerticalInsets = protectedVerticalInsets
        let timelineLayout = TimelineLayout(
            startDate: startDate,
            endDate: endDate,
            availableIntervals: availableIntervals
        )
        let timelineScale = TimelineScale(duration: timelineLayout.recordedDuration)
        self.timelineScale = timelineScale
        self.timelineLayout = timelineLayout
        self._feedbackStep = State(
            initialValue: Self.feedbackStep(
                for: selection.wrappedValue,
                from: startDate,
                interval: timelineScale.minorInterval
            )
        )
        self._selectionFollowsCurrentTime = State(initialValue: availableIntervals.isEmpty)
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = ScrubberMetrics(
                size: proxy.size,
                safeAreaInsets: proxy.safeAreaInsets,
                protectedVerticalInsets: protectedVerticalInsets
            )
            let activeSelection = activeSelection(currentDate: currentDate)
            let selectionY = yPosition(for: activeSelection, in: metrics)
            let currentY = isDateInRange(currentDate) && hasCaptureData(around: currentDate) ? yPosition(for: currentDate, in: metrics) : nil

            ZStack(alignment: .topTrailing) {
//                markProtectionGradient(in: metrics, isScrubbing: isScrubbing)

                marks(
                    activeY: selectionY,
                    currentY: currentY,
                    isScrubbing: isScrubbing,
                    in: metrics
                )

                if let currentY, !Self.isCurrentMinute(activeSelection, comparedTo: currentDate, calendar: calendar) {
                    nowIndicator(at: currentY, isScrubbing: isScrubbing, in: metrics)
                }

                scrubberPill(for: activeSelection, currentDate: currentDate)
                    .position(x: metrics.pillX, y: selectionY)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(in: metrics, currentDate: currentDate))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Time scrubber")
            .accessibilityValue(accessibilityValue(for: activeSelection, currentDate: currentDate))
            .onDisappear {
                externalIsScrubbing = false
                isDragActive = false
                visualScrubDate = nil
            }
        }
        .task {
            await updateCurrentTimeEveryMinute()
        }
        .frame(width: 116)
        .sensoryFeedback(.selection, trigger: feedbackStep)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.45), trigger: scrubInteractionFeedbackID)
    }

    private func markProtectionGradient(in metrics: ScrubberMetrics, isScrubbing: Bool) -> some View {
        LinearGradient(
            colors: [
                .black.opacity(0),
                .black.opacity(0.58)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: metrics.protectionWidth(isScrubbing: isScrubbing), height: metrics.size.height)
        .position(
            x: metrics.width - metrics.protectionWidth(isScrubbing: isScrubbing) / 2,
            y: metrics.size.height / 2
        )
        .animation(.smooth(duration: 0.18), value: isScrubbing)
        .allowsHitTesting(false)
    }

    private func marks(
        activeY: CGFloat,
        currentY: CGFloat?,
        isScrubbing: Bool,
        in metrics: ScrubberMetrics
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            ForEach(timelineMarks, id: \.id) { mark in
                let y = yPosition(for: mark.date, in: metrics)
                let hidesMark = shouldHideTimelineMark(
                    y: y,
                    isMajor: mark.isMajor,
                    currentY: currentY
                )
                let presentation = metrics.presentation(
                    for: mark,
                    distanceFromActiveSelection: abs(y - activeY),
                    isScrubbing: isScrubbing
                )

                Capsule()
                    .fill(mark.isMajor ? .white.opacity(0.8) : .white.opacity(0.5))
                    .frame(width: presentation.width, height: presentation.height)
                    .opacity(hidesMark ? 0 : 1)
                    .position(x: presentation.centerX, y: y)
                    .animation(.smooth(duration: 0.18), value: isScrubbing)

                if mark.isMajor {
                    let hidesText = shouldHideTimelineText(
                        y: y,
                        currentY: currentY
                    )

                    Text(timelineScale.label(for: mark.date))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: ScrubberMetrics.hourLabelWidth, alignment: .trailing)
                        .opacity(isScrubbing && !hidesText ? 1 : 0)
                        .position(x: presentation.labelCenterX, y: y)
                        .transition(.move(edge: .trailing))
                        .animation(.smooth(duration: 0.18), value: isScrubbing)
                }
            }
        }
    }

    private func nowIndicator(at y: CGFloat, isScrubbing: Bool, in metrics: ScrubberMetrics) -> some View {
        ZStack(alignment: .topTrailing) {
            Capsule()
                .fill(.white.opacity(1))
                .frame(width: ScrubberMetrics.nowMarkWidth, height: ScrubberMetrics.markHeight)
                .position(x: metrics.nowMarkCenterX, y: y)

            Text("Now")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .frame(width: ScrubberMetrics.nowLabelWidth, alignment: .trailing)
                .position(x: metrics.nowLabelCenterX, y: y)
        }
        .animation(.smooth(duration: 0.18), value: isScrubbing)
    }

    private func scrubberPill(for date: Date, currentDate: Date) -> some View {
        Text(scrubberTitle(for: date, currentDate: currentDate))
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .transaction { transaction in
                transaction.animation = nil
            }
        .foregroundStyle(.primary)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private func dragGesture(in metrics: ScrubberMetrics, currentDate: Date) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($isScrubbing) { _, state, _ in
                state = true
            }
            .onChanged { value in
                externalIsScrubbing = true
                beginScrubInteractionIfNeeded()
                let proposedDate = date(for: value.location.y, in: metrics)
                let nextSelection = snappedSelection(
                    for: proposedDate,
                    currentDate: currentDate
                )
                visualScrubDate = min(proposedDate, currentDate)
                selectionFollowsCurrentTime = false
                updateSelection(nextSelection)

                let nextStep = Self.feedbackStep(
                    for: nextSelection,
                    from: startDate,
                    interval: timelineScale.minorInterval
                )
                if nextStep != feedbackStep {
                    feedbackStep = nextStep
                }
            }
            .onEnded { value in
                externalIsScrubbing = false
                endScrubInteractionIfNeeded()
                let proposedDate = date(for: value.location.y, in: metrics)
                let nextSelection = snappedSelection(
                    for: proposedDate,
                    currentDate: currentDate
                )
                visualScrubDate = nil
                selectionFollowsCurrentTime = Self.isCurrentMinute(
                    nextSelection,
                    comparedTo: currentDate,
                    calendar: calendar
                )

                if selectionFollowsCurrentTime {
                    updateSelection(clamped(currentDate))
                }
            }
    }

    private func beginScrubInteractionIfNeeded() {
        guard !isDragActive else {
            return
        }

        isDragActive = true
        scrubInteractionFeedbackID += 1
    }

    private func endScrubInteractionIfNeeded() {
        guard isDragActive else {
            return
        }

        isDragActive = false
        scrubInteractionFeedbackID += 1
    }

    private var timelineMarks: [TimelineMark] {
        guard endDate > startDate else {
            return []
        }

        let minorInterval = timelineScale.minorInterval
        let markInterval = max(1, minorInterval / 2)
        let majorInterval = timelineScale.majorInterval
        var marks: [TimelineMark] = []
        let displayDuration = timelineLayout.recordedDuration
        var markOffset: TimeInterval = 0
        var markIndex = 0

        while markOffset <= displayDuration {
            marks.append(TimelineMark(
                date: timelineLayout.date(forDisplayOffset: markOffset),
                displayOffset: markOffset,
                isMajor: markOffset.truncatingRemainder(dividingBy: majorInterval) < 0.5
            ))
            markIndex += 1
            markOffset = markInterval * TimeInterval(markIndex)
        }

        return marks
    }

    private func yPosition(for date: Date, in metrics: ScrubberMetrics) -> CGFloat {
        guard endDate > startDate else {
            return metrics.trackTop
        }

        let progress = timelineLayout.progress(for: clamped(date))
        return metrics.trackTop + (metrics.trackHeight * progress)
    }

    private func date(for yPosition: CGFloat, in metrics: ScrubberMetrics) -> Date {
        guard endDate > startDate else {
            return startDate
        }

        let clampedY = min(max(yPosition, metrics.trackTop), metrics.trackBottom)
        let progress = (clampedY - metrics.trackTop) / metrics.trackHeight

        return clamped(timelineLayout.date(for: progress))
    }

    private func updateSelection(_ nextSelection: Date) {
        selection = nextSelection
    }

    private func snappedSelection(for date: Date, currentDate: Date) -> Date {
        if date >= currentDate || Self.isCurrentMinute(date, comparedTo: currentDate, calendar: calendar) {
            return clamped(currentDate)
        }

        guard !availableIntervals.isEmpty else {
            return date
        }

        let clampedDate = clamped(date)
        if hasCaptureData(around: clampedDate) {
            return clampedDate
        }

        if let nextInterval = availableIntervals.first(where: { $0.start > clampedDate }) {
            return clamped(nextInterval.start)
        }

        if let previousInterval = availableIntervals.last(where: { $0.end < clampedDate }) {
            return clamped(previousInterval.end)
        }

        return clampedDate
    }

    private func shouldHideTimelineMark(
        y: CGFloat,
        isMajor: Bool,
        currentY: CGFloat?
    ) -> Bool {
        guard let currentY else {
            return false
        }

        return abs(y - currentY) <= (isMajor ? 8 : 6)
    }

    private func shouldHideTimelineText(
        y: CGFloat,
        currentY: CGFloat?
    ) -> Bool {
        guard let currentY else {
            return false
        }

        return abs(y - currentY) <= 18
    }

    private func clamped(_ date: Date) -> Date {
        min(max(date, startDate), endDate)
    }

    private func isDateInRange(_ date: Date) -> Bool {
        date >= startDate && date <= endDate
    }

    private func hasCaptureData(around date: Date) -> Bool {
        if availableIntervals.isEmpty {
            return true
        }

        return availableIntervals.contains { interval in
            interval.contains(date)
        }
    }

    private func activeSelection(currentDate: Date) -> Date {
        if let visualScrubDate {
            return clamped(visualScrubDate)
        }

        if selectionFollowsCurrentTime, !isScrubbing {
            return clamped(currentDate)
        }

        return clamped(selection)
    }

    private func scrubberTitle(for date: Date, currentDate: Date) -> String {
        if Self.isCurrentMinute(date, comparedTo: currentDate, calendar: calendar) {
            return "Now"
        }

        return timelineScale.label(for: date)
    }

    private func accessibilityValue(for date: Date, currentDate: Date) -> String {
        if Self.isCurrentMinute(date, comparedTo: currentDate, calendar: calendar) {
            return "Now"
        }

        return timelineScale.label(for: date)
    }

    private func syncSelectionWithCurrentTime(_ currentDate: Date) {
        guard selectionFollowsCurrentTime else {
            return
        }

        selection = clamped(currentDate)
    }

    @MainActor
    private func updateCurrentTimeEveryMinute() async {
        while !Task.isCancelled {
            let nextDate = Date.now
            currentDate = nextDate
            syncSelectionWithCurrentTime(nextDate)

            do {
                try await Task.sleep(
                    for: .nanoseconds(Self.nanosecondsUntilNextMinute(from: nextDate))
                )
            } catch {
                return
            }
        }
    }

    private static func feedbackStep(for date: Date, from startDate: Date, interval: TimeInterval) -> Int {
        max(0, Int(floor(date.timeIntervalSince(startDate) / interval)))
    }

    private static func isCurrentMinute(_ date: Date, comparedTo currentDate: Date, calendar: Calendar) -> Bool {
        calendar.compare(date, to: currentDate, toGranularity: .minute) == .orderedSame
    }

    private static func nanosecondsUntilNextMinute(from date: Date) -> Int64 {
        let secondsIntoMinute = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 60)
        let secondsUntilNextMinute = max(0.1, 60 - secondsIntoMinute)

        return Int64(secondsUntilNextMinute * 1_000_000_000)
    }
}

private struct ScrubberMetrics {
    static let pillWidth: CGFloat = 92
    static let pillHeight: CGFloat = 46
    static let minimumTopClearance: CGFloat = 44
    static let markHeight: CGFloat = 2
    static let nowMarkWidth: CGFloat = 24
    static let nowLabelWidth: CGFloat = 36
    static let snapDistance: CGFloat = 24

    let size: CGSize
    let safeAreaInsets: EdgeInsets
    let protectedVerticalInsets: EdgeInsets

    var width: CGFloat {
        size.width
    }

    var trackTop: CGFloat {
        max(safeAreaInsets.top + protectedVerticalInsets.top, Self.minimumTopClearance)
            + Self.pillHeight / 2
            + 12
    }

    var trackBottom: CGFloat {
        max(
            trackTop,
            size.height
                - safeAreaInsets.bottom
                - protectedVerticalInsets.bottom
                - Self.pillHeight / 2
                - 12
        )
    }

    var trackHeight: CGFloat {
        max(1, trackBottom - trackTop)
    }

    var pillX: CGFloat {
        width - Self.pillRightInset - Self.pillWidth / 2
    }

    var nowMarkCenterX: CGFloat {
        width - Self.baseMarkTrailingOffset - Self.nowMarkWidth / 2
    }

    var nowLabelCenterX: CGFloat {
        nowMarkCenterX - Self.nowMarkWidth / 2 - Self.nowLabelSpacing - Self.nowLabelWidth / 2
    }

    func presentation(
        for mark: TimelineMark,
        distanceFromActiveSelection distance: CGFloat,
        isScrubbing: Bool
    ) -> TimelineMarkPresentation {
        let influence = isScrubbing ? morphInfluence(for: distance) : 0
        let easedInfluence = influence * influence * (3 - 2 * influence)
        let baseWidth: CGFloat
        if mark.isMajor {
            baseWidth = isScrubbing ? 12 : 8
        } else {
            baseWidth = isScrubbing ? 8 : 4
        }
        let baseHeight: CGFloat = Self.markHeight

        // Marks retreat only while dragging, leaving a thumb path without changing
        // their visual weight or length.
        let trailingOffset = Self.baseMarkTrailingOffset + Self.maximumMarkRetreat * easedInfluence
        let centerX = width - trailingOffset - baseWidth / 2

        return TimelineMarkPresentation(
            centerX: centerX,
            labelCenterX: centerX - baseWidth / 2 - Self.hourLabelSpacing - Self.hourLabelWidth / 2,
            width: baseWidth,
            height: baseHeight
        )
    }

    private func morphInfluence(for distance: CGFloat) -> CGFloat {
        let normalizedDistance = min(max(distance / Self.morphRadius, 0), 1)

        return 1 - normalizedDistance
    }

    private static let pillRightInset: CGFloat = 12
    private static let baseMarkTrailingOffset: CGFloat = 6
    private static let maximumMarkRetreat: CGFloat = 28
    private static let morphRadius: CGFloat = 92
    private static let nowLabelSpacing: CGFloat = 6
    private static let hourLabelSpacing: CGFloat = 6
    private static let restingProtectionWidth: CGFloat = 76
    private static let expandedProtectionWidth: CGFloat = 166
    fileprivate static let hourLabelWidth: CGFloat = 70

    func protectionWidth(isScrubbing: Bool) -> CGFloat {
        isScrubbing ? Self.expandedProtectionWidth : Self.restingProtectionWidth
    }
}

private struct TimelineMark: Identifiable {
    let date: Date
    let displayOffset: TimeInterval
    let isMajor: Bool

    var id: TimeInterval {
        displayOffset
    }
}

private struct TimelineLayout {
    let segments: [TimelineSegment]

    var recordedSegments: [TimelineSegment] {
        segments
    }

    var recordedDuration: TimeInterval {
        let duration = segments
            .reduce(0) { partialResult, segment in
                partialResult + segment.realDuration
            }

        return max(duration, 1)
    }

    private var totalDisplayDuration: TimeInterval {
        max(segments.last?.displayEnd ?? 1, 1)
    }

    init(startDate: Date, endDate: Date, availableIntervals: [DateInterval]) {
        guard endDate > startDate else {
            self.segments = [
                TimelineSegment(
                    startDate: startDate,
                    endDate: startDate.addingTimeInterval(1),
                    displayStart: 0,
                    displayDuration: 1,
                    isAvailable: true
                )
            ]
            return
        }

        let normalizedIntervals = Self.normalizedIntervals(
            availableIntervals,
            startDate: startDate,
            endDate: endDate
        )

        guard !normalizedIntervals.isEmpty else {
            self.segments = [
                TimelineSegment(
                    startDate: startDate,
                    endDate: endDate,
                    displayStart: 0,
                    displayDuration: endDate.timeIntervalSince(startDate),
                    isAvailable: true
                )
            ]
            return
        }

        var nextDisplayStart: TimeInterval = 0
        var segments: [TimelineSegment] = []

        // Demo captures are sparse, so the scrubber bends time by stitching
        // recorded intervals together and allocating no visual space to gaps.
        for interval in normalizedIntervals {
            let availableSegment = Self.segment(
                startDate: interval.start,
                endDate: interval.end,
                displayStart: nextDisplayStart,
                isAvailable: true
            )
            segments.append(availableSegment)
            nextDisplayStart = availableSegment.displayEnd
        }

        self.segments = segments
    }

    func progress(for date: Date) -> CGFloat {
        let segment = segment(containing: date)
        let offset = segment.displayOffset(for: date)

        return CGFloat(min(max(offset / totalDisplayDuration, 0), 1))
    }

    func date(for progress: CGFloat) -> Date {
        let clampedProgress = min(max(progress, 0), 1)
        let displayOffset = totalDisplayDuration * TimeInterval(clampedProgress)
        return date(forDisplayOffset: displayOffset)
    }

    /// Converts a stitched timeline offset back into the real timestamp at that
    /// visual position so tick marks stay evenly spaced even when capture gaps
    /// are removed from the scrubber track.
    func date(forDisplayOffset displayOffset: TimeInterval) -> Date {
        let segment = segment(containingDisplayOffset: displayOffset)

        return segment.date(forDisplayOffset: displayOffset)
    }

    private func segment(containing date: Date) -> TimelineSegment {
        segments.first { segment in
            date >= segment.startDate && date <= segment.endDate
        } ?? nearestSegment(to: date)
    }

    private func segment(containingDisplayOffset displayOffset: TimeInterval) -> TimelineSegment {
        segments.first { segment in
            displayOffset >= segment.displayStart && displayOffset <= segment.displayEnd
        } ?? segments.last ?? TimelineSegment(
            startDate: .now,
            endDate: .now.addingTimeInterval(1),
            displayStart: 0,
            displayDuration: 1,
            isAvailable: true
        )
    }

    private func nearestSegment(to date: Date) -> TimelineSegment {
        guard let firstSegment = segments.first else {
            return TimelineSegment(
                startDate: date,
                endDate: date.addingTimeInterval(1),
                displayStart: 0,
                displayDuration: 1,
                isAvailable: true
            )
        }

        var nearestSegment = firstSegment
        var nearestDistance = TimeInterval.greatestFiniteMagnitude

        for segment in segments {
            let distance = min(
                abs(date.timeIntervalSince(segment.startDate)),
                abs(date.timeIntervalSince(segment.endDate))
            )
            if distance < nearestDistance {
                nearestDistance = distance
                nearestSegment = segment
            }
        }

        return nearestSegment
    }

    private static func normalizedIntervals(
        _ intervals: [DateInterval],
        startDate: Date,
        endDate: Date
    ) -> [DateInterval] {
        let clampedIntervals = intervals.compactMap { interval -> DateInterval? in
            let start = max(interval.start, startDate)
            let end = min(interval.end, endDate)
            guard end > start else {
                return nil
            }

            return DateInterval(start: start, end: end)
        }
        .sorted { $0.start < $1.start }

        var mergedIntervals: [DateInterval] = []
        for interval in clampedIntervals {
            guard let lastInterval = mergedIntervals.last else {
                mergedIntervals.append(interval)
                continue
            }

            if interval.start <= lastInterval.end {
                mergedIntervals[mergedIntervals.count - 1] = DateInterval(
                    start: lastInterval.start,
                    end: max(lastInterval.end, interval.end)
                )
            } else {
                mergedIntervals.append(interval)
            }
        }

        return mergedIntervals
    }

    private static func segment(
        startDate: Date,
        endDate: Date,
        displayStart: TimeInterval,
        isAvailable: Bool
    ) -> TimelineSegment {
        let realDuration = max(1, endDate.timeIntervalSince(startDate))
        return TimelineSegment(
            startDate: startDate,
            endDate: endDate,
            displayStart: displayStart,
            displayDuration: realDuration,
            isAvailable: isAvailable
        )
    }
}

private struct TimelineSegment: Identifiable {
    let startDate: Date
    let endDate: Date
    let displayStart: TimeInterval
    let displayDuration: TimeInterval
    let isAvailable: Bool

    var id: String {
        "\(startDate.timeIntervalSinceReferenceDate)-\(endDate.timeIntervalSinceReferenceDate)-\(isAvailable)"
    }

    var displayEnd: TimeInterval {
        displayStart + displayDuration
    }

    var realDuration: TimeInterval {
        max(1, endDate.timeIntervalSince(startDate))
    }

    func displayOffset(for date: Date) -> TimeInterval {
        let realProgress = min(max(date.timeIntervalSince(startDate) / realDuration, 0), 1)
        return displayStart + displayDuration * realProgress
    }

    func date(forDisplayOffset displayOffset: TimeInterval) -> Date {
        let displayProgress = min(max((displayOffset - displayStart) / max(displayDuration, 1), 0), 1)
        return startDate.addingTimeInterval(realDuration * displayProgress)
    }
}

private struct TimelineScale {
    let minorInterval: TimeInterval
    let majorInterval: TimeInterval
    let showsSeconds: Bool

    init(duration: TimeInterval) {
        switch duration {
        case ...120:
            self.minorInterval = 1
            self.majorInterval = 10
            self.showsSeconds = true
        case ...600:
            self.minorInterval = 10
            self.majorInterval = 60
            self.showsSeconds = true
        case ...3_600:
            self.minorInterval = 60
            self.majorInterval = 5 * 60
            self.showsSeconds = false
        case ...14_400:
            self.minorInterval = 5 * 60
            self.majorInterval = 30 * 60
            self.showsSeconds = false
        case ...43_200:
            self.minorInterval = 15 * 60
            self.majorInterval = 60 * 60
            self.showsSeconds = false
        default:
            self.minorInterval = 30 * 60
            self.majorInterval = 2 * 60 * 60
            self.showsSeconds = false
        }
    }

    func label(for date: Date) -> String {
        if showsSeconds {
            return date.formatted(.dateTime.hour().minute().second())
        }

        return date.formatted(date: .omitted, time: .shortened)
    }
}

private struct TimelineMarkPresentation {
    let centerX: CGFloat
    let labelCenterX: CGFloat
    let width: CGFloat
    let height: CGFloat
}

private struct ScrubberPreview: View {
    @State private var selection = Date.previewTime(
        hour: Calendar.current.component(.hour, from: .now),
        minute: Calendar.current.component(.minute, from: .now)
    )

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.red

            Scrubber(
                selection: $selection,
                startDate: .previewTime(hour: 6),
                endDate: .previewTime(hour: 22)
            )
            .ignoresSafeArea(edges: .vertical)
        }
    }
}

private extension Date {
    static func previewTime(hour: Int, minute: Int = 0) -> Date {
        Calendar.current.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: .now
        ) ?? .now
    }
}

#Preview("6 AM to 10 PM") {
    ScrubberPreview()
}
