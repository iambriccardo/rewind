//
//  PhoneCaptureController.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

#if os(iOS)
import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import Observation
import OSLog
import UniformTypeIdentifiers

enum PhoneCaptureBufferPolicy {
    static let duration: TimeInterval = 20
    static let maximumFrames = 140
}

/// Coordinates phone camera and microphone capture for the temporary capture mode.
///
/// This controller deliberately mirrors the later glasses ingestion boundary: one session, a
/// throttled video stream, and an audio stream that flow into `CaptureStreamEndpoint`.
@MainActor
@Observable
final class PhoneCaptureController: NSObject {
    let cachedFrames: AsyncStream<CachedCaptureFrame>

    static let captureFrameRate = 7
    static let streamFrameRate = 1
    static let streamLongestEdge = 384
    static let streamJPEGQuality: CGFloat = 0.62
    static let deviceCacheFrameRate = 7
    static let deviceCacheLongestEdge = 1_280
    static let deviceCacheHEICQuality: CGFloat = 0.52
    static let rewindBufferDurationMilliseconds = Int(PhoneCaptureBufferPolicy.duration * 1_000)
    static let rewindBufferMaximumFrames = PhoneCaptureBufferPolicy.maximumFrames
    static let audioSampleRate = 16_000
    static let audioChunkMilliseconds = 250

    private(set) var state: PhoneCaptureState = .idle
    private(set) var capturedVideoFrameCount = 0
    private(set) var streamedVideoFrameCount = 0
    private(set) var cachedVideoFrameCount = 0
    private(set) var audioChunkCount = 0
    private(set) var startedAt: Date?
    private(set) var lastVideoFrameAt: Date?
    private(set) var lastStreamedVideoFrameAt: Date?
    private(set) var lastCachedVideoFrameAt: Date?
    private(set) var lastAudioChunkAt: Date?

    var isRunning: Bool {
        state == .running
    }

    var previewSession: AVCaptureSession {
        captureSession
    }

    @ObservationIgnored private let captureSession = AVCaptureSession()
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let audioOutput = AVCaptureAudioDataOutput()
    @ObservationIgnored private let captureOutputQueue = DispatchQueue(
        label: "app.vogelhaus.Rewind.capture-output",
        qos: .userInitiated
    )
    @ObservationIgnored private let endpoint: CaptureStreamEndpoint
    @ObservationIgnored private let frameCache: CaptureFrameCache
    @ObservationIgnored private let sampleProcessor: CaptureSampleProcessor
    @ObservationIgnored private let cachedFrameContinuation: AsyncStream<CachedCaptureFrame>.Continuation
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vogelhaus.Rewind",
        category: "PhoneCapture"
    )

    @ObservationIgnored private lazy var videoSampleDelegate = CaptureVideoSampleDelegate(processor: sampleProcessor)
    @ObservationIgnored private lazy var audioSampleDelegate = CaptureAudioSampleDelegate(processor: sampleProcessor)

    @ObservationIgnored private var currentSession: CaptureStreamSession?
    @ObservationIgnored private var metricsTask: Task<Void, Never>?
    @ObservationIgnored private var isConfigured = false
    @ObservationIgnored private var lastAcceptedFrameSecond: TimeInterval?
    @ObservationIgnored private var lastStreamedFrameSecond: TimeInterval?
    @ObservationIgnored private var lastCachedFrameSecond: TimeInterval?

    init(
        endpoint: CaptureStreamEndpoint = CaptureStreamEndpoint(),
        frameCache: CaptureFrameCache = .shared
    ) {
        self.endpoint = endpoint
        self.frameCache = frameCache
        var cachedFrameContinuation: AsyncStream<CachedCaptureFrame>.Continuation!
        self.cachedFrames = AsyncStream { continuation in
            cachedFrameContinuation = continuation
        }
        self.cachedFrameContinuation = cachedFrameContinuation
        self.sampleProcessor = CaptureSampleProcessor(
            endpoint: endpoint,
            frameCache: frameCache,
            cachedFrameContinuation: cachedFrameContinuation
        )
        super.init()
        startMetricsListener()
    }

    deinit {
        metricsTask?.cancel()
    }

    func start() async {
        guard state == .idle else {
            return
        }

        state = .requestingAccess

        guard await requestAccess(for: .video), await requestAccess(for: .audio) else {
            state = .failed("Camera and microphone access are required.")
            logger.error("Phone capture permission request failed")
            return
        }
        guard state == .requestingAccess else {
            return
        }

        do {
            try configureAudioSession()
            try configureIfNeeded()
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("Failed to configure phone capture: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard state == .requestingAccess else {
            deactivateAudioSession()
            return
        }

        let streamSession = CaptureStreamSession(
            id: UUID(),
            startedAt: Date(),
            captureFrameRate: Self.captureFrameRate,
            streamFrameRate: Self.streamFrameRate,
            streamLongestEdge: Self.streamLongestEdge,
            streamJPEGQuality: Double(Self.streamJPEGQuality),
            source: .phone,
            rewindBufferDurationMilliseconds: Self.rewindBufferDurationMilliseconds,
            rewindBufferMaximumFrames: Self.rewindBufferMaximumFrames,
            deviceFrameIntervalMilliseconds: 1_000 / Self.deviceCacheFrameRate,
            realtimeImageIntervalMilliseconds: 1_000 / Self.streamFrameRate,
            audioChunkMilliseconds: Self.audioChunkMilliseconds,
            audioSampleRate: Self.audioSampleRate
        )

        currentSession = streamSession
        capturedVideoFrameCount = 0
        streamedVideoFrameCount = 0
        cachedVideoFrameCount = 0
        audioChunkCount = 0
        lastAcceptedFrameSecond = nil
        lastStreamedFrameSecond = nil
        lastCachedFrameSecond = nil
        startedAt = streamSession.startedAt
        lastVideoFrameAt = nil
        lastStreamedVideoFrameAt = nil
        lastCachedVideoFrameAt = nil
        lastAudioChunkAt = nil

        startSampleProcessorSession(streamSession)
        await endpoint.startSession(streamSession)
        guard state == .requestingAccess else {
            stopSampleProcessorSession()
            await endpoint.finishSession(id: streamSession.id)
            currentSession = nil
            startedAt = nil
            deactivateAudioSession()
            return
        }
        await startCaptureSession()
        guard state == .requestingAccess else {
            await stopCaptureSession()
            stopSampleProcessorSession()
            await endpoint.finishSession(id: streamSession.id)
            currentSession = nil
            startedAt = nil
            deactivateAudioSession()
            return
        }
        state = .running
        logger.info(
            "Phone capture started at \(Self.captureFrameRate, privacy: .public) FPS with \(Self.streamFrameRate, privacy: .public) FPS server stream and saved-memory buffer plus \(Self.deviceCacheFrameRate, privacy: .public) FPS device cache"
        )
    }

    func stop() async {
        guard state != .idle, state != .stopping else {
            return
        }

        guard currentSession != nil else {
            state = .idle
            return
        }

        state = .stopping
        await stopCaptureSession()

        if let sessionID = currentSession?.id {
            await endpoint.finishSession(id: sessionID)
        }
        stopSampleProcessorSession()

        currentSession = nil
        startedAt = nil
        lastAcceptedFrameSecond = nil
        lastStreamedFrameSecond = nil
        lastCachedFrameSecond = nil
        deactivateAudioSession()
        state = .idle
        logger.info("Phone capture stopped")
    }

    private func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func configureIfNeeded() throws {
        guard !isConfigured else {
            return
        }

        captureSession.beginConfiguration()
        defer {
            captureSession.commitConfiguration()
        }

        if captureSession.canSetSessionPreset(.hd1280x720) {
            captureSession.sessionPreset = .hd1280x720
        } else if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
            logger.error("Falling back to high camera preset because 720p is unavailable")
        } else {
            throw PhoneCaptureError.hdCaptureUnavailable
        }

        guard
            let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
            captureSession.canAddInput(videoInput)
        else {
            throw PhoneCaptureError.videoInputUnavailable
        }

        do {
            try configureFrameRate(on: videoDevice)
        } catch {
            logger.error("Falling back to default camera frame rate: \(error.localizedDescription, privacy: .public)")
        }
        captureSession.addInput(videoInput)

        guard
            let audioDevice = AVCaptureDevice.default(for: .audio),
            let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
            captureSession.canAddInput(audioInput)
        else {
            throw PhoneCaptureError.audioInputUnavailable
        }

        captureSession.addInput(audioInput)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        guard captureSession.canAddOutput(videoOutput) else {
            throw PhoneCaptureError.videoOutputUnavailable
        }

        captureSession.addOutput(videoOutput)
        videoOutput.setSampleBufferDelegate(videoSampleDelegate, queue: captureOutputQueue)

        guard captureSession.canAddOutput(audioOutput) else {
            throw PhoneCaptureError.audioOutputUnavailable
        }

        captureSession.addOutput(audioOutput)
        audioOutput.setSampleBufferDelegate(audioSampleDelegate, queue: captureOutputQueue)

        isConfigured = true
    }

    private func startCaptureSession() async {
        await runCaptureSessionCommand(.start)
    }

    private func stopCaptureSession() async {
        await runCaptureSessionCommand(.stop)
    }

    private func startSampleProcessorSession(_ session: CaptureStreamSession) {
        captureOutputQueue.sync {
            sampleProcessor.startSession(session)
        }
    }

    private func stopSampleProcessorSession() {
        captureOutputQueue.sync {
            sampleProcessor.stopSession()
        }
    }

    private func startMetricsListener() {
        guard metricsTask == nil else {
            return
        }

        metricsTask = Task { [weak self, sampleProcessor] in
            for await update in sampleProcessor.metrics {
                self?.apply(update)
            }
        }
    }

    private func apply(_ update: CaptureMetricsUpdate) {
        switch update {
        case let .videoCaptured(count, timestamp):
            capturedVideoFrameCount = count
            lastVideoFrameAt = timestamp
        case let .videoStreamed(count, timestamp):
            streamedVideoFrameCount = count
            lastStreamedVideoFrameAt = timestamp
        case let .videoCached(count, timestamp):
            cachedVideoFrameCount = count
            lastCachedVideoFrameAt = timestamp
        case let .audioChunked(count, timestamp):
            audioChunkCount = count
            lastAudioChunkAt = timestamp
        }
    }

    private func runCaptureSessionCommand(_ command: CaptureSessionCommand.Kind) async {
        await withCheckedContinuation { continuation in
            let command = CaptureSessionCommand(
                kind: command,
                captureSession: captureSession,
                continuation: continuation
            )
            Thread.detachNewThreadSelector(
                #selector(CaptureSessionCommand.run),
                toTarget: command,
                with: nil
            )
        }
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try audioSession.setPreferredSampleRate(Double(Self.audioSampleRate))
        try audioSession.setPreferredIOBufferDuration(TimeInterval(Self.audioChunkMilliseconds) / 1_000)
        try audioSession.setActive(true)
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error("Failed to deactivate phone capture audio session: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func configureFrameRate(on device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer {
            device.unlockForConfiguration()
        }

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(Self.captureFrameRate))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
    }

}

private struct ServerImage {
    let data: Data
    let width: Int
    let height: Int
}

private struct DeviceCacheImage {
    let data: Data
    let width: Int
    let height: Int
}

private struct PortraitCaptureImage {
    let cgImage: CGImage
    let width: Int
    let height: Int
}

private enum CaptureMetricsUpdate: Sendable {
    case videoCaptured(Int, Date)
    case videoStreamed(Int, Date)
    case videoCached(Int, Date)
    case audioChunked(Int, Date)
}

private final class CaptureSampleProcessor {
    let metrics: AsyncStream<CaptureMetricsUpdate>

    private let endpoint: CaptureStreamEndpoint
    private let frameCache: CaptureFrameCache
    private let cachedFrameContinuation: AsyncStream<CachedCaptureFrame>.Continuation
    private let metricsContinuation: AsyncStream<CaptureMetricsUpdate>.Continuation
    private let audioEncoder = CaptureAudioPCMEncoder(
        outputSampleRate: PhoneCaptureController.audioSampleRate,
        chunkMilliseconds: PhoneCaptureController.audioChunkMilliseconds
    )
    private let imageContext = CIContext()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vogelhaus.Rewind",
        category: "CaptureSampleProcessor"
    )

    private var currentSession: CaptureStreamSession?
    private var lastAcceptedFrameSecond: TimeInterval?
    private var lastStreamedFrameSecond: TimeInterval?
    private var lastCachedFrameSecond: TimeInterval?
    private var capturedVideoFrameCount = 0
    private var streamedVideoFrameCount = 0
    private var cachedVideoFrameCount = 0
    private var audioChunkCount = 0

    init(
        endpoint: CaptureStreamEndpoint,
        frameCache: CaptureFrameCache,
        cachedFrameContinuation: AsyncStream<CachedCaptureFrame>.Continuation
    ) {
        self.endpoint = endpoint
        self.frameCache = frameCache
        self.cachedFrameContinuation = cachedFrameContinuation
        var metricsContinuation: AsyncStream<CaptureMetricsUpdate>.Continuation!
        self.metrics = AsyncStream { continuation in
            metricsContinuation = continuation
        }
        self.metricsContinuation = metricsContinuation
    }

    func startSession(_ session: CaptureStreamSession) {
        currentSession = session
        lastAcceptedFrameSecond = nil
        lastStreamedFrameSecond = nil
        lastCachedFrameSecond = nil
        capturedVideoFrameCount = 0
        streamedVideoFrameCount = 0
        cachedVideoFrameCount = 0
        audioChunkCount = 0
    }

    func stopSession() {
        currentSession = nil
        lastAcceptedFrameSecond = nil
        lastStreamedFrameSecond = nil
        lastCachedFrameSecond = nil
        audioEncoder.reset()
    }

    func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let streamSession = currentSession else {
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if let lastAcceptedFrameSecond,
           timestamp - lastAcceptedFrameSecond < 1.0 / Double(PhoneCaptureController.captureFrameRate) {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        lastAcceptedFrameSecond = timestamp
        capturedVideoFrameCount += 1
        let capturedAt = Date()
        let deviceFrameUUID = UUID().uuidString
        metricsContinuation.yield(.videoCaptured(capturedVideoFrameCount, capturedAt))

        if shouldCacheVideoFrame(at: timestamp) {
            if let cachedImage = makeDeviceCacheImage(from: pixelBuffer) {
                cachedVideoFrameCount += 1
                lastCachedFrameSecond = timestamp
                metricsContinuation.yield(.videoCached(cachedVideoFrameCount, capturedAt))

                let frame = DeviceCaptureFrame(
                    deviceFrameUUID: deviceFrameUUID,
                    memoryEventID: nil,
                    sessionID: streamSession.id,
                    sequenceNumber: cachedVideoFrameCount,
                    timestamp: capturedAt,
                    width: cachedImage.width,
                    height: cachedImage.height,
                    data: cachedImage.data,
                    fileExtension: "heic"
                )

                Task {
                    if let cachedFrame = await frameCache.storeFrame(frame) {
                        _ = cachedFrameContinuation.yield(cachedFrame)
                    }
                }
            } else {
                logger.error("Failed to create cached video frame")
            }
        }

        guard shouldStreamVideoFrame(at: timestamp) else {
            return
        }

        guard let serverImage = makeServerImage(from: pixelBuffer) else {
            logger.error("Failed to create server video frame")
            return
        }

        streamedVideoFrameCount += 1
        lastStreamedFrameSecond = timestamp
        metricsContinuation.yield(.videoStreamed(streamedVideoFrameCount, capturedAt))

        let frame = CaptureVideoFrame(
            sessionID: streamSession.id,
            deviceFrameUUID: deviceFrameUUID,
            sequenceNumber: streamedVideoFrameCount,
            timestamp: capturedAt,
            width: serverImage.width,
            height: serverImage.height,
            jpegQuality: Double(PhoneCaptureController.streamJPEGQuality),
            data: serverImage.data
        )

        Task {
            await endpoint.receiveVideoFrame(frame)
        }
    }

    func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let streamSession = currentSession else {
            return
        }

        let capturedAt = Date()
        for chunkData in audioEncoder.chunks(from: sampleBuffer) {
            audioChunkCount += 1
            metricsContinuation.yield(.audioChunked(audioChunkCount, capturedAt))

            let chunk = CaptureAudioChunk(
                sessionID: streamSession.id,
                sequenceNumber: audioChunkCount,
                timestamp: capturedAt,
                duration: TimeInterval(PhoneCaptureController.audioChunkMilliseconds) / 1_000,
                sampleCount: chunkData.count / MemoryLayout<Int16>.size,
                mimeType: "audio/pcm;rate=\(PhoneCaptureController.audioSampleRate)",
                data: chunkData
            )

            Task {
                await endpoint.receiveAudioChunk(chunk)
            }
        }
    }

    private func shouldStreamVideoFrame(at timestamp: TimeInterval) -> Bool {
        guard let lastStreamedFrameSecond else {
            return true
        }

        return timestamp - lastStreamedFrameSecond >= 1.0 / Double(PhoneCaptureController.streamFrameRate)
    }

    private func shouldCacheVideoFrame(at timestamp: TimeInterval) -> Bool {
        guard let lastCachedFrameSecond else {
            return true
        }

        return timestamp - lastCachedFrameSecond >= 1.0 / Double(PhoneCaptureController.deviceCacheFrameRate)
    }

    private func makeServerImage(from pixelBuffer: CVPixelBuffer) -> ServerImage? {
        guard let portraitImage = makePortraitImage(from: pixelBuffer) else {
            return nil
        }

        let longestEdge = max(portraitImage.width, portraitImage.height)
        guard longestEdge > 0 else {
            return nil
        }

        let scale = min(1, CGFloat(PhoneCaptureController.streamLongestEdge) / CGFloat(longestEdge))
        let targetWidth = max(1, Int((CGFloat(portraitImage.width) * scale).rounded()))
        let targetHeight = max(1, Int((CGFloat(portraitImage.height) * scale).rounded()))

        guard
            let resizedImage = resizedImage(
                portraitImage.cgImage,
                targetWidth: targetWidth,
                targetHeight: targetHeight
            ),
            let data = encodedImageData(
                resizedImage,
                type: .jpeg,
                quality: PhoneCaptureController.streamJPEGQuality
            )
        else {
            return nil
        }

        return ServerImage(data: data, width: targetWidth, height: targetHeight)
    }

    private func makeDeviceCacheImage(from pixelBuffer: CVPixelBuffer) -> DeviceCacheImage? {
        guard let portraitImage = makePortraitImage(from: pixelBuffer) else {
            return nil
        }

        let longestEdge = max(portraitImage.width, portraitImage.height)
        guard longestEdge > 0 else {
            return nil
        }

        let scale = min(1, CGFloat(PhoneCaptureController.deviceCacheLongestEdge) / CGFloat(longestEdge))
        let targetWidth = max(1, Int((CGFloat(portraitImage.width) * scale).rounded()))
        let targetHeight = max(1, Int((CGFloat(portraitImage.height) * scale).rounded()))

        guard
            let resizedImage = resizedImage(
                portraitImage.cgImage,
                targetWidth: targetWidth,
                targetHeight: targetHeight
            ),
            let opaqueImage = opaqueImage(
                from: resizedImage,
                width: targetWidth,
                height: targetHeight
            ),
            let data = encodedImageData(
                opaqueImage,
                type: .heic,
                quality: PhoneCaptureController.deviceCacheHEICQuality
            )
        else {
            return nil
        }

        return DeviceCacheImage(data: data, width: targetWidth, height: targetHeight)
    }

    private func makePortraitImage(from pixelBuffer: CVPixelBuffer) -> PortraitCaptureImage? {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let portraitImage = sourceWidth > sourceHeight ? sourceImage.oriented(.right) : sourceImage
        let extent = portraitImage.extent.integral

        guard let cgImage = imageContext.createCGImage(portraitImage, from: extent) else {
            return nil
        }

        return PortraitCaptureImage(
            cgImage: cgImage,
            width: Int(extent.width),
            height: Int(extent.height)
        )
    }

    private func resizedImage(_ image: CGImage, targetWidth: Int, targetHeight: Int) -> CGImage? {
        guard targetWidth > 0, targetHeight > 0 else {
            return nil
        }

        guard image.width != targetWidth || image.height != targetHeight else {
            return image
        }

        let sourceImage = CIImage(cgImage: image)
        let scaleX = CGFloat(targetWidth) / CGFloat(image.width)
        let scaleY = CGFloat(targetHeight) / CGFloat(image.height)
        let resizedImage = sourceImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let targetRect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        return imageContext.createCGImage(resizedImage, from: targetRect)
    }

    private func opaqueImage(from image: CGImage, width: Int, height: Int) -> CGImage? {
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func encodedImageData(_ image: CGImage, type: UTType, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return data as Data
    }
}

private final class CaptureVideoSampleDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let processor: CaptureSampleProcessor

    init(processor: CaptureSampleProcessor) {
        self.processor = processor
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        processor.handleVideoSampleBuffer(sampleBuffer)
    }
}

private final class CaptureAudioSampleDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let processor: CaptureSampleProcessor

    init(processor: CaptureSampleProcessor) {
        self.processor = processor
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        processor.handleAudioSampleBuffer(sampleBuffer)
    }
}

private final class CaptureSessionCommand: NSObject {
    enum Kind {
        case start
        case stop
    }

    private let kind: Kind
    private let captureSession: AVCaptureSession
    private let continuation: CheckedContinuation<Void, Never>
    private var retainedSelf: CaptureSessionCommand?

    init(
        kind: Kind,
        captureSession: AVCaptureSession,
        continuation: CheckedContinuation<Void, Never>
    ) {
        self.kind = kind
        self.captureSession = captureSession
        self.continuation = continuation
        super.init()
        self.retainedSelf = self
    }

    /// Runs the blocking capture-session operation off the main actor.
    ///
    /// `AVCaptureSession` is not modeled as `Sendable`, but the start/stop call
    /// itself is synchronous and isolated to this command thread.
    @objc func run() {
        switch kind {
        case .start:
            captureSession.startRunning()
        case .stop:
            captureSession.stopRunning()
        }

        continuation.resume()
        retainedSelf = nil
    }
}

private final class CaptureAudioPCMEncoder {
    private let outputSampleRate: Double
    private let chunkSampleCount: Int
    private var pendingSamples: [Int16] = []
    private var pendingStartIndex = 0

    init(outputSampleRate: Int, chunkMilliseconds: Int) {
        self.outputSampleRate = Double(outputSampleRate)
        self.chunkSampleCount = max(1, outputSampleRate * chunkMilliseconds / 1_000)
    }

    func chunks(from sampleBuffer: CMSampleBuffer) -> [Data] {
        guard let samples = pcmSamples(from: sampleBuffer), !samples.isEmpty else {
            return []
        }

        pendingSamples.append(contentsOf: samples)

        var chunks: [Data] = []
        while pendingSamples.count - pendingStartIndex >= chunkSampleCount {
            let chunkEndIndex = pendingStartIndex + chunkSampleCount
            let chunkSamples = Array(pendingSamples[pendingStartIndex..<chunkEndIndex])
            pendingStartIndex = chunkEndIndex
            chunks.append(Self.data(from: chunkSamples))
        }

        compactPendingSamplesIfNeeded()
        return chunks
    }

    func reset() {
        pendingSamples.removeAll()
        pendingStartIndex = 0
    }

    private func compactPendingSamplesIfNeeded() {
        guard pendingStartIndex > chunkSampleCount * 4 else {
            return
        }

        pendingSamples.removeFirst(pendingStartIndex)
        pendingStartIndex = 0
    }

    private func pcmSamples(from sampleBuffer: CMSampleBuffer) -> [Int16]? {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
            let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else {
            return nil
        }

        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &pointer
        )

        guard status == kCMBlockBufferNoErr, let pointer, totalLength > 0 else {
            return nil
        }

        let inputSampleRate = streamDescription.mSampleRate
        let channelCount = max(1, Int(streamDescription.mChannelsPerFrame))
        let flags = streamDescription.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0

        let monoSamples: [Float]
        if isFloat, streamDescription.mBitsPerChannel == 32 {
            monoSamples = readFloat32Samples(pointer: pointer, byteCount: totalLength, channelCount: channelCount)
        } else if isSignedInteger, streamDescription.mBitsPerChannel == 16 {
            monoSamples = readInt16Samples(pointer: pointer, byteCount: totalLength, channelCount: channelCount)
        } else {
            return nil
        }

        return downsampleToPCM16(monoSamples, inputSampleRate: inputSampleRate)
    }

    private func readFloat32Samples(pointer: UnsafeMutablePointer<Int8>, byteCount: Int, channelCount: Int) -> [Float] {
        let sampleCount = byteCount / MemoryLayout<Float>.size
        let floatPointer = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: sampleCount)
        return readMonoSamples(sampleCount: sampleCount, channelCount: channelCount) { index in
            floatPointer[index]
        }
    }

    private func readInt16Samples(pointer: UnsafeMutablePointer<Int8>, byteCount: Int, channelCount: Int) -> [Float] {
        let sampleCount = byteCount / MemoryLayout<Int16>.size
        let intPointer = UnsafeRawPointer(pointer).bindMemory(to: Int16.self, capacity: sampleCount)
        return readMonoSamples(sampleCount: sampleCount, channelCount: channelCount) { index in
            Float(Int16(littleEndian: intPointer[index])) / Float(Int16.max)
        }
    }

    private func readMonoSamples(sampleCount: Int, channelCount: Int, sampleAt: (Int) -> Float) -> [Float] {
        let frameCount = sampleCount / channelCount
        var monoSamples: [Float] = []
        monoSamples.reserveCapacity(frameCount)

        for frameIndex in 0..<frameCount {
            var sample: Float = 0
            for channelIndex in 0..<channelCount {
                sample += sampleAt(frameIndex * channelCount + channelIndex)
            }

            monoSamples.append(sample / Float(channelCount))
        }

        return monoSamples
    }

    private func downsampleToPCM16(_ input: [Float], inputSampleRate: Double) -> [Int16] {
        guard !input.isEmpty, inputSampleRate > 0 else {
            return []
        }

        if abs(inputSampleRate - outputSampleRate) < 0.5 {
            return input.map(Self.pcm16Sample)
        }

        let ratio = inputSampleRate / outputSampleRate
        let outputLength = max(1, Int(Double(input.count) / ratio))
        var output: [Int16] = []
        output.reserveCapacity(outputLength)

        for index in 0..<outputLength {
            let start = Int(Double(index) * ratio)
            let end = min(input.count, Int(Double(index + 1) * ratio))
            guard start < end else {
                continue
            }

            let sum = input[start..<end].reduce(Float(0), +)
            let sample = max(-1, min(1, sum / Float(end - start)))
            output.append(Self.pcm16Sample(sample))
        }

        return output
    }

    private nonisolated static func pcm16Sample(_ sample: Float) -> Int16 {
        let clampedSample = max(-1, min(1, sample))
        return clampedSample < 0 ? Int16(clampedSample * 32_768) : Int16(clampedSample * 32_767)
    }

    private nonisolated static func data(from samples: [Int16]) -> Data {
        var littleEndianSamples = samples.map(\.littleEndian)
        return Data(bytes: &littleEndianSamples, count: littleEndianSamples.count * MemoryLayout<Int16>.size)
    }
}

enum PhoneCaptureState: Equatable {
    case idle
    case requestingAccess
    case running
    case stopping
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            "Idle"
        case .requestingAccess:
            "Requesting access"
        case .running:
            "Capturing"
        case .stopping:
            "Stopping"
        case .failed:
            "Error"
        }
    }
}

private enum PhoneCaptureError: LocalizedError {
    case hdCaptureUnavailable
    case videoInputUnavailable
    case audioInputUnavailable
    case videoOutputUnavailable
    case audioOutputUnavailable

    var errorDescription: String? {
        switch self {
        case .hdCaptureUnavailable:
            "The phone camera does not support 720p capture."
        case .videoInputUnavailable:
            "The phone camera could not be configured."
        case .audioInputUnavailable:
            "The phone microphone could not be configured."
        case .videoOutputUnavailable:
            "The video stream could not be attached."
        case .audioOutputUnavailable:
            "The audio stream could not be attached."
        }
    }
}
#endif
