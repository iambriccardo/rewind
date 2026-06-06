//
//  AgentAudioPlayer.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

#if os(iOS)
import AVFoundation
import Foundation
import OSLog

/// Plays backend `agent.media` PCM audio responses without adding visible controls.
@MainActor
final class AgentAudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vogelhaus.Rewind",
        category: "AgentAudioPlayer"
    )

    private var isConfigured = false

    func play(_ audio: RewindAgentAudio) {
        guard let pcmData = Data(base64Encoded: audio.base64Data) else {
            logger.error("Dropped agent audio because base64 decoding failed")
            return
        }

        let sampleRate = Self.sampleRate(from: audio.mimeType) ?? 24_000
        guard let buffer = makePCMBuffer(data: pcmData, sampleRate: sampleRate) else {
            logger.error("Dropped agent audio because PCM buffer creation failed")
            return
        }

        do {
            try configureIfNeeded(format: buffer.format)
            playerNode.scheduleBuffer(buffer)
            if !playerNode.isPlaying {
                playerNode.play()
            }
        } catch {
            logger.error("Failed to play agent audio: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        guard isConfigured else {
            return
        }

        playerNode.stop()
        engine.stop()
        engine.detach(playerNode)
        isConfigured = false
    }

    private func configureIfNeeded(format: AVAudioFormat) throws {
        guard !isConfigured else {
            return
        }

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        try engine.start()
        isConfigured = true
    }

    private func makePCMBuffer(data: Data, sampleRate: Int) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else {
            return nil
        }

        guard
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)),
            let output = buffer.floatChannelData?[0]
        else {
            return nil
        }

        data.withUnsafeBytes { rawBuffer in
            guard let input = rawBuffer.bindMemory(to: Int16.self).baseAddress else {
                return
            }

            for index in 0..<sampleCount {
                output[index] = Float(Int16(littleEndian: input[index])) / Float(Int16.max)
            }
        }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        return buffer
    }

    private static func sampleRate(from mimeType: String) -> Int? {
        let marker = "rate="
        guard let range = mimeType.range(of: marker) else {
            return nil
        }

        let suffix = mimeType[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits)
    }
}
#endif
