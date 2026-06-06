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
import UIKit

/// Coordinates phone camera and microphone capture for the temporary capture mode.
///
/// This controller deliberately mirrors the later glasses ingestion boundary: one session, a
/// throttled video stream, and an audio stream that flow into `CaptureStreamEndpoint`.
@MainActor
@Observable
final class PhoneCaptureController: NSObject {
    static let captureFrameRate = 7
    static let streamFrameRate = 1
    static let streamLongestEdge = 384
    static let streamJPEGQuality: CGFloat = 0.62
    static let deviceCacheFrameRate = 1
    static let deviceCacheLongestEdge = 1_280
    static let deviceCacheHEICQuality: CGFloat = 0.52

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
    @ObservationIgnored private let imageContext = CIContext()
    @ObservationIgnored private let endpoint: CaptureStreamEndpoint
    @ObservationIgnored private let frameCache: CaptureFrameCache
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vogelhaus.Rewind",
        category: "PhoneCapture"
    )

    @ObservationIgnored private var currentSession: CaptureStreamSession?
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
        super.init()
    }

    func start() async {
        guard !isRunning else {
            return
        }

        state = .requestingAccess

        guard await requestAccess(for: .video), await requestAccess(for: .audio) else {
            state = .failed("Camera and microphone access are required.")
            logger.error("Capture mode permission request failed")
            return
        }

        do {
            try configureIfNeeded()
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("Failed to configure phone capture: \(error.localizedDescription, privacy: .public)")
            return
        }

        let streamSession = CaptureStreamSession(
            id: UUID(),
            startedAt: Date(),
            captureFrameRate: Self.captureFrameRate,
            streamFrameRate: Self.streamFrameRate,
            streamLongestEdge: Self.streamLongestEdge,
            streamJPEGQuality: Double(Self.streamJPEGQuality),
            source: .phone
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

        await endpoint.startSession(streamSession)
        captureSession.startRunning()
        state = .running
        logger.info(
            "Phone capture started at \(Self.captureFrameRate, privacy: .public) FPS with \(Self.streamFrameRate, privacy: .public) FPS server stream and \(Self.deviceCacheFrameRate, privacy: .public) FPS device cache"
        )
    }

    func stop() async {
        guard currentSession != nil else {
            state = .idle
            return
        }

        state = .stopping
        captureSession.stopRunning()

        if let sessionID = currentSession?.id {
            await endpoint.finishSession(id: sessionID)
        }

        currentSession = nil
        startedAt = nil
        lastAcceptedFrameSecond = nil
        lastStreamedFrameSecond = nil
        lastCachedFrameSecond = nil
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

        guard captureSession.canSetSessionPreset(.hd1280x720) else {
            throw PhoneCaptureError.hdCaptureUnavailable
        }

        captureSession.sessionPreset = .hd1280x720

        guard
            let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
            captureSession.canAddInput(videoInput)
        else {
            throw PhoneCaptureError.videoInputUnavailable
        }

        try configureFrameRate(on: videoDevice)
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
        videoOutput.setSampleBufferDelegate(self, queue: .main)

        guard captureSession.canAddOutput(audioOutput) else {
            throw PhoneCaptureError.audioOutputUnavailable
        }

        captureSession.addOutput(audioOutput)
        audioOutput.setSampleBufferDelegate(self, queue: .main)

        isConfigured = true
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

    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let streamSession = currentSession, state == .running else {
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if let lastAcceptedFrameSecond, timestamp - lastAcceptedFrameSecond < 1.0 / Double(Self.captureFrameRate) {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        lastAcceptedFrameSecond = timestamp
        capturedVideoFrameCount += 1
        let capturedAt = Date()
        lastVideoFrameAt = capturedAt

        if shouldCacheVideoFrame(at: timestamp) {
            if let cachedImage = makeDeviceCacheImage(from: pixelBuffer) {
                cachedVideoFrameCount += 1
                lastCachedFrameSecond = timestamp
                lastCachedVideoFrameAt = capturedAt

                let frame = DeviceCaptureFrame(
                    sessionID: streamSession.id,
                    sequenceNumber: cachedVideoFrameCount,
                    timestamp: capturedAt,
                    width: cachedImage.width,
                    height: cachedImage.height,
                    data: cachedImage.data
                )

                Task {
                    await frameCache.storeFrame(frame)
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
        lastStreamedVideoFrameAt = capturedAt

        let frame = CaptureVideoFrame(
            sessionID: streamSession.id,
            sequenceNumber: streamedVideoFrameCount,
            timestamp: capturedAt,
            width: serverImage.width,
            height: serverImage.height,
            jpegQuality: Double(Self.streamJPEGQuality),
            data: serverImage.data
        )

        Task {
            await endpoint.receiveVideoFrame(frame)
        }
    }

    private func shouldStreamVideoFrame(at timestamp: TimeInterval) -> Bool {
        guard let lastStreamedFrameSecond else {
            return true
        }

        return timestamp - lastStreamedFrameSecond >= 1.0 / Double(Self.streamFrameRate)
    }

    private func shouldCacheVideoFrame(at timestamp: TimeInterval) -> Bool {
        guard let lastCachedFrameSecond else {
            return true
        }

        return timestamp - lastCachedFrameSecond >= 1.0 / Double(Self.deviceCacheFrameRate)
    }

    private func makeServerImage(from pixelBuffer: CVPixelBuffer) -> ServerImage? {
        guard let portraitImage = makePortraitImage(from: pixelBuffer) else {
            return nil
        }

        let longestEdge = max(portraitImage.width, portraitImage.height)
        guard longestEdge > 0 else {
            return nil
        }

        let scale = min(1, CGFloat(Self.streamLongestEdge) / CGFloat(longestEdge))
        let targetWidth = max(1, Int((CGFloat(portraitImage.width) * scale).rounded()))
        let targetHeight = max(1, Int((CGFloat(portraitImage.height) * scale).rounded()))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: targetWidth, height: targetHeight), format: format)
        let resizedImage = renderer.image { _ in
            UIImage(cgImage: portraitImage.cgImage)
                .draw(in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        }

        guard let data = resizedImage.jpegData(compressionQuality: Self.streamJPEGQuality) else {
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

        let scale = min(1, CGFloat(Self.deviceCacheLongestEdge) / CGFloat(longestEdge))
        let targetWidth = max(1, Int((CGFloat(portraitImage.width) * scale).rounded()))
        let targetHeight = max(1, Int((CGFloat(portraitImage.height) * scale).rounded()))

        let cgImage: CGImage
        if targetWidth == portraitImage.width, targetHeight == portraitImage.height {
            cgImage = portraitImage.cgImage
        } else {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: targetWidth, height: targetHeight), format: format)
            let resizedImage = renderer.image { _ in
                UIImage(cgImage: portraitImage.cgImage)
                    .draw(in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            }

            guard let resizedCGImage = resizedImage.cgImage else {
                return nil
            }

            cgImage = resizedCGImage
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: Self.deviceCacheHEICQuality
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return DeviceCacheImage(data: data as Data, width: targetWidth, height: targetHeight)
    }

    private func makePortraitImage(from pixelBuffer: CVPixelBuffer) -> PortraitCaptureImage? {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let sourceCGImage = imageContext.createCGImage(image, from: image.extent) else {
            return nil
        }

        guard sourceWidth > sourceHeight else {
            return PortraitCaptureImage(cgImage: sourceCGImage, width: sourceWidth, height: sourceHeight)
        }

        let targetSize = CGSize(width: sourceHeight, height: sourceWidth)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let rotatedImage = renderer.image { _ in
            UIImage(cgImage: sourceCGImage, scale: 1, orientation: .right)
                .draw(in: CGRect(origin: .zero, size: targetSize))
        }

        guard let rotatedCGImage = rotatedImage.cgImage else {
            return nil
        }

        return PortraitCaptureImage(
            cgImage: rotatedCGImage,
            width: Int(targetSize.width),
            height: Int(targetSize.height)
        )
    }

    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let streamSession = currentSession, state == .running else {
            return
        }

        audioChunkCount += 1
        let capturedAt = Date()
        lastAudioChunkAt = capturedAt

        let duration = CMSampleBufferGetDuration(sampleBuffer).seconds
        let chunk = CaptureAudioChunk(
            sessionID: streamSession.id,
            sequenceNumber: audioChunkCount,
            timestamp: capturedAt,
            duration: duration.isFinite ? duration : 0,
            sampleCount: CMSampleBufferGetNumSamples(sampleBuffer)
        )

        Task {
            await endpoint.receiveAudioChunk(chunk)
        }
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

extension PhoneCaptureController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        MainActor.assumeIsolated {
            if output === videoOutput {
                handleVideoSampleBuffer(sampleBuffer)
            } else if output === audioOutput {
                handleAudioSampleBuffer(sampleBuffer)
            }
        }
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
            "Requesting Access"
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
