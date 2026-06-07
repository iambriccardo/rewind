//
//  WearableRememberSpeechDetector.swift
//  Rewind
//
//  Created by Codex on 6/7/26.
//

#if os(iOS)
import AVFoundation
import Foundation
import OSLog
import Speech

/// Local speech intent emitted when wearable mode hears a remembered-memory phrase.
///
/// This event is intentionally UI-local. It does not confirm that the backend
/// saved a memory; it only lets the wearable simulation feel immediate while the
/// server continues to process the unchanged audio stream independently.
struct WearableRememberSpeechIntent: Sendable {
    let detectedAt: Date
    let matchedPhrase: String
}

/// Detects local "remember this" speech intents from the existing capture audio stream.
///
/// The detector consumes copied `CaptureAudioChunk` values from
/// `PhoneCaptureController`, batches them into one-second Speech requests, checks
/// the result against `WearableRememberKeywordMatcher`, then discards the
/// transcript. It never opens its own microphone input, so it does not compete
/// with `AVCaptureAudioDataOutput` or the backend audio stream.
@MainActor
final class WearableRememberSpeechDetector {
    let intents: AsyncStream<WearableRememberSpeechIntent>

    private let speechRecognizer: SFSpeechRecognizer?
    private let matcher: WearableRememberKeywordMatcher
    private let intentContinuation: AsyncStream<WearableRememberSpeechIntent>.Continuation
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vogelhaus.Rewind",
        category: "WearableRememberSpeechDetector"
    )

    private var audioTask: Task<Void, Never>?
    private var lastIntentDate: Date?

    init(
        speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "en_US")),
        matcher: WearableRememberKeywordMatcher = WearableRememberKeywordMatcher()
    ) {
        self.speechRecognizer = speechRecognizer
        self.matcher = matcher
        var intentContinuation: AsyncStream<WearableRememberSpeechIntent>.Continuation!
        self.intents = AsyncStream { continuation in
            intentContinuation = continuation
        }
        self.intentContinuation = intentContinuation
    }

    func start(audioChunks: AsyncStream<CaptureAudioChunk>) async {
        guard audioTask == nil else {
            return
        }

        let authorizationStatus = await Self.requestSpeechAuthorization()
        guard authorizationStatus == .authorized else {
            logger.error("Wearable remember speech detection disabled because Speech authorization is \(String(describing: authorizationStatus), privacy: .public)")
            return
        }

        guard speechRecognizer != nil else {
            logger.error("Wearable remember speech detection disabled because no Speech recognizer is available")
            return
        }

        audioTask = Task { [weak self] in
            await self?.process(audioChunks: audioChunks)
        }
        logger.info("Started wearable remember speech detection")
    }

    func stop() {
        audioTask?.cancel()
        audioTask = nil
        lastIntentDate = nil
    }

    private func process(audioChunks: AsyncStream<CaptureAudioChunk>) async {
        var pendingAudio = Data()
        var pendingSampleCount = 0

        for await chunk in audioChunks {
            guard !Task.isCancelled else {
                break
            }

            pendingAudio.append(chunk.data)
            pendingSampleCount += chunk.sampleCount

            let batchSampleCount = max(1, chunk.sampleRate)
            guard pendingSampleCount >= batchSampleCount else {
                continue
            }

            let batch = WearableRememberSpeechBatch(
                data: pendingAudio,
                sampleRate: chunk.sampleRate,
                sampleCount: pendingSampleCount
            )

            pendingAudio.removeAll(keepingCapacity: true)
            pendingSampleCount = 0

            guard let transcript = await recognize(batch: batch) else {
                continue
            }

            if let matchedPhrase = matcher.match(in: transcript), shouldEmitIntent() {
                lastIntentDate = Date()
                intentContinuation.yield(WearableRememberSpeechIntent(
                    detectedAt: Date(),
                    matchedPhrase: matchedPhrase
                ))
                logger.info("Detected wearable remember speech intent for phrase \(matchedPhrase, privacy: .public)")
            }
        }
    }

    private func recognize(batch: WearableRememberSpeechBatch) async -> String? {
        guard
            let speechRecognizer,
            speechRecognizer.isAvailable,
            let request = makeRecognitionRequest(),
            let buffer = batch.makeAudioBuffer()
        else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            var didResume = false
            let task = speechRecognizer.recognitionTask(with: request) { result, error in
                Task { @MainActor in
                    guard !didResume else {
                        return
                    }

                    if let result, result.isFinal {
                        didResume = true
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    } else if let error {
                        didResume = true
                        continuation.resume(returning: nil)
                        self.logger.error("Wearable remember speech recognition failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            request.append(buffer)
            request.endAudio()

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.4))
                guard !didResume else {
                    return
                }

                didResume = true
                task.cancel()
                continuation.resume(returning: nil)
            }
        }
    }

    private func makeRecognitionRequest() -> SFSpeechAudioBufferRecognitionRequest? {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        if speechRecognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }

        return request
    }

    private func shouldEmitIntent() -> Bool {
        guard let lastIntentDate else {
            return true
        }

        return Date().timeIntervalSince(lastIntentDate) >= 3.0
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

private struct WearableRememberSpeechBatch {
    let data: Data
    let sampleRate: Int
    let sampleCount: Int

    func makeAudioBuffer() -> AVAudioPCMBuffer? {
        guard
            sampleCount > 0,
            data.count >= sampleCount * MemoryLayout<Int16>.size,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(sampleRate),
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleCount)
            ),
            let channelData = buffer.int16ChannelData
        else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: Int16.self).baseAddress else {
                return
            }

            channelData[0].update(from: source, count: sampleCount)
        }
        return buffer
    }
}

/// Matches locally transcribed text against the wearable remembered-memory trigger vocabulary.
///
/// The list intentionally contains 100 short phrases instead of one-word triggers
/// so accidental mentions of "memory" or "remember" are less likely to fire the
/// capture animation. Matching is normalized and transcript-only; no transcript
/// text is stored after the batch has been checked.
nonisolated struct WearableRememberKeywordMatcher {
    private let normalizedPhrases: [(display: String, normalized: String)]

    init(phrases: [String] = Self.triggerPhrases) {
        self.normalizedPhrases = phrases.map { phrase in
            (display: phrase, normalized: Self.normalized(phrase))
        }
    }

    func match(in transcript: String) -> String? {
        let normalizedTranscript = Self.normalized(transcript)
        guard !normalizedTranscript.isEmpty else {
            return nil
        }

        return normalizedPhrases.first { phrase in
            normalizedTranscript.contains(phrase.normalized)
        }?.display
    }

    private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static let triggerPhrases = [
        "remember this",
        "remember that",
        "remember this moment",
        "remember that moment",
        "remember what I see",
        "remember what I'm seeing",
        "remember what I am seeing",
        "remember where I am",
        "remember this place",
        "remember this room",
        "remember this view",
        "remember this scene",
        "remember this object",
        "remember this item",
        "remember this note",
        "remember this document",
        "remember these notes",
        "remember this page",
        "remember this screen",
        "remember my surroundings",
        "remember the surroundings",
        "remember the room",
        "remember the table",
        "remember the sign",
        "remember the label",
        "remember the address",
        "remember the name",
        "remember this name",
        "remember this address",
        "remember this location",
        "remember this detail",
        "remember these details",
        "remember for later",
        "remember it for later",
        "save this",
        "save that",
        "save this moment",
        "save that moment",
        "save what I see",
        "save what I'm seeing",
        "save what I am seeing",
        "save this place",
        "save this room",
        "save this view",
        "save this scene",
        "save this object",
        "save this item",
        "save this note",
        "save this document",
        "save these notes",
        "save this page",
        "save this screen",
        "save my surroundings",
        "save the surroundings",
        "save the room",
        "save the table",
        "save the sign",
        "save the label",
        "save the address",
        "save the name",
        "save this name",
        "save this address",
        "save this location",
        "save this detail",
        "save these details",
        "save it for later",
        "capture this",
        "capture that",
        "capture this moment",
        "capture that moment",
        "capture what I see",
        "capture what I'm seeing",
        "capture what I am seeing",
        "capture this place",
        "capture this room",
        "capture this view",
        "capture this scene",
        "capture this object",
        "capture this item",
        "capture this note",
        "capture this document",
        "capture these notes",
        "capture this page",
        "capture this screen",
        "capture my surroundings",
        "capture the surroundings",
        "capture this address",
        "capture this location",
        "capture this detail",
        "take a memory",
        "make a memory",
        "store this memory",
        "store this moment",
        "store this for later",
        "keep this memory",
        "keep this moment",
        "keep this for later",
        "log this memory",
        "mark this memory",
        "pin this memory"
    ]
}

private extension CaptureAudioChunk {
    var sampleRate: Int {
        let prefix = "audio/pcm;rate="
        guard mimeType.hasPrefix(prefix), let sampleRate = Int(mimeType.dropFirst(prefix.count)) else {
            return PhoneCaptureController.audioSampleRate
        }

        return sampleRate
    }
}
#endif
