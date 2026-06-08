//
//  RewindProtocolModels.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

import Foundation

nonisolated struct RewindSessionHello: Encodable, Sendable {
    let type = "session.hello"
    let protocolVersion = 1
    let device: Device
    let buffers: Buffers
    let context: Context

    enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol_version"
        case device
        case buffers
        case context
    }

    nonisolated struct Device: Encodable, Sendable {
        let id: String
        let kind: String
    }

    nonisolated struct Buffers: Encodable, Sendable {
        let rewind: Rewind

        nonisolated struct Rewind: Encodable, Sendable {
            let durationMs: Int
            let frameIntervalMs: Int
            let maxFrames: Int

            enum CodingKeys: String, CodingKey {
                case durationMs = "duration_ms"
                case frameIntervalMs = "frame_interval_ms"
                case maxFrames = "max_frames"
            }
        }
    }

    nonisolated struct Context: Encodable, Sendable {
        let currentTime: String
        let timeZone: String
        let utcOffsetMinutes: Int

        enum CodingKeys: String, CodingKey {
            case currentTime = "current_time"
            case timeZone = "time_zone"
            case utcOffsetMinutes = "utc_offset_minutes"
        }

        static func current(now: Date = Date(), timeZone: TimeZone = .current) -> Context {
            Context(
                currentTime: ISO8601DateFormatter.rewindProtocol.string(from: now),
                timeZone: timeZone.identifier,
                utcOffsetMinutes: timeZone.secondsFromGMT(for: now) / 60
            )
        }
    }
}

nonisolated struct RewindUserTextMessage: Encodable, Sendable {
    let type = "user.text"
    let text: String
}

nonisolated struct RewindUserMediaMessage: Encodable, Sendable {
    let type = "user.media"
    let modality: String
    let mimeType: String
    let data: String
    let seq: Int
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case type
        case modality
        case mimeType = "mime_type"
        case data
        case seq
        case timestamp
    }
}

nonisolated struct RewindMediaEndMessage: Encodable, Sendable {
    let type = "user.media_end"
    let modality: String
}

nonisolated enum RewindServerMessage: Sendable {
    case sessionReady(RewindSessionReady)
    case liveState(RewindLiveState)
    case agentMessage(String)
    case agentMedia(RewindAgentMedia)
    case saveRequest(RewindSaveRequest)
    case searchStarted(RewindSearchStarted)
    case searchResults(RewindSearchResults)
    case error(String)
    case unknown(String)
}

nonisolated struct RewindSessionReady: Decodable, Sendable {
    let sessionID: String
    let userID: String
    let deviceID: String
    let maxRewindDurationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case userID = "user_id"
        case deviceID = "device_id"
        case maxRewindDurationSeconds = "max_rewind_duration_seconds"
    }
}

nonisolated struct RewindLiveState: Decodable, Sendable {
    let state: String
}

nonisolated struct RewindAgentMedia: Decodable, Sendable {
    let modality: String
    let mimeType: String?
    let data: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case modality
        case mimeType = "mime_type"
        case data
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modality = try container.decode(String.self, forKey: .modality)
        self.mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        self.data = try container.decodeIfPresent(FlexibleBase64Data.self, forKey: .data)?.base64String
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
    }
}

/// Decodes backend media payloads that may arrive as a base64 string or a JSON
/// byte array/Buffer-shaped object if an upstream SDK returns binary data.
nonisolated private struct FlexibleBase64Data: Decodable {
    let base64String: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let string = try? container.decode(String.self) {
            self.base64String = string
            return
        }

        if let bytes = try? container.decode([UInt8].self) {
            self.base64String = Data(bytes).base64EncodedString()
            return
        }

        let keyedContainer = try decoder.container(keyedBy: CodingKeys.self)
        if let bytes = try? keyedContainer.decode([UInt8].self, forKey: .data) {
            self.base64String = Data(bytes).base64EncodedString()
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected base64 string, byte array, or Buffer-shaped object."
        )
    }

    private enum CodingKeys: String, CodingKey {
        case data
    }
}

nonisolated struct RewindSaveRequest: Decodable, Identifiable, Sendable {
    let requestID: String
    let eventID: String
    let uploadURL: String
    let title: String
    let description: String
    let statusText: String
    let rewindDurationSeconds: Double
    let captureAnchorUTC: String?
    let captureDurationMs: Int?
    let captureWindowStartedAt: String?
    let captureWindowEndedAt: String?
    let includeFrameImages: Bool
    let frameEmbeddingMode: String

    var id: String { eventID }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case eventID = "event_id"
        case uploadURL = "upload_url"
        case title
        case description
        case statusText = "status_text"
        case rewindDurationSeconds = "rewind_duration_seconds"
        case captureAnchorUTC = "capture_anchor_utc"
        case captureDurationMs = "capture_duration_ms"
        case captureWindowStartedAt = "capture_window_started_at"
        case captureWindowEndedAt = "capture_window_ended_at"
        case includeFrameImages = "include_frame_images"
        case frameEmbeddingMode = "frame_embedding_mode"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestID = try container.decode(String.self, forKey: .requestID)
        self.eventID = try container.decode(String.self, forKey: .eventID)
        self.uploadURL = try container.decode(String.self, forKey: .uploadURL)
        self.title = try container.decode(String.self, forKey: .title)
        self.description = try container.decode(String.self, forKey: .description)
        self.statusText = try container.decodeIfPresent(String.self, forKey: .statusText) ?? "Remembering \(title)."
        self.rewindDurationSeconds = try container.decode(Double.self, forKey: .rewindDurationSeconds)
        self.captureAnchorUTC = try container.decodeIfPresent(String.self, forKey: .captureAnchorUTC)
        self.captureDurationMs = try container.decodeIfPresent(Int.self, forKey: .captureDurationMs)
        self.captureWindowStartedAt = try container.decodeIfPresent(String.self, forKey: .captureWindowStartedAt)
        self.captureWindowEndedAt = try container.decodeIfPresent(String.self, forKey: .captureWindowEndedAt)
        self.includeFrameImages = try container.decode(Bool.self, forKey: .includeFrameImages)
        self.frameEmbeddingMode = try container.decode(String.self, forKey: .frameEmbeddingMode)
    }
}

/// Search progress event emitted by the live protocol before hydrated results are available.
nonisolated struct RewindSearchStarted: Decodable, Sendable {
    let requestID: String
    let query: String
    let text: String
    let filters: Filters?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case query
        case text
        case filters
    }

    nonisolated struct Filters: Decodable, Sendable {
        let timeRange: TimeRange?
        let entities: [String]?
        let locationHint: String?

        enum CodingKeys: String, CodingKey {
            case timeRange = "time_range"
            case entities
            case locationHint = "location_hint"
        }

        nonisolated struct TimeRange: Decodable, Sendable {
            let startedAfter: String?
            let endedBefore: String?

            enum CodingKeys: String, CodingKey {
                case startedAfter = "started_after"
                case endedBefore = "ended_before"
            }
        }
    }
}

nonisolated struct RewindSearchResults: Decodable, Sendable {
    let query: String
    let filters: Filters?
    let results: [RewindProtocolResult]

    nonisolated struct Filters: Decodable, Sendable {
        let timeRange: TimeRange?
        let entities: [String]?
        let locationHint: String?

        enum CodingKeys: String, CodingKey {
            case timeRange = "time_range"
            case entities
            case locationHint = "location_hint"
        }

        nonisolated struct TimeRange: Decodable, Sendable {
            let startedAfter: String?
            let endedBefore: String?

            enum CodingKeys: String, CodingKey {
                case startedAfter = "started_after"
                case endedBefore = "ended_before"
            }
        }
    }
}

nonisolated struct RewindProtocolResult: Decodable, Identifiable, Sendable {
    let eventID: String
    let title: String
    let description: String
    let entities: [String]
    let locationHint: String?
    let startedAt: String?
    let endedAt: String?
    let score: Score
    let frameRefs: [FrameRef]

    var id: String { eventID }

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case title
        case description
        case entities
        case locationHint = "location_hint"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case score
        case frameRefs = "frame_refs"
    }

    nonisolated struct Score: Decodable, Sendable {
        let similarity: Double?
        let eventSimilarity: Double?
        let frameSimilarity: Double?
        let textRank: Double?

        enum CodingKeys: String, CodingKey {
            case similarity
            case eventSimilarity = "event_similarity"
            case frameSimilarity = "frame_similarity"
            case textRank = "text_rank"
        }
    }

    nonisolated struct FrameRef: Decodable, Sendable {
        let frameID: String?
        let deviceFrameUUID: String
        let capturedAt: String?
        let offsetMs: Int?

        enum CodingKeys: String, CodingKey {
            case frameID = "frame_id"
            case deviceFrameUUID = "device_frame_uuid"
            case capturedAt = "captured_at"
            case offsetMs = "offset_ms"
        }
    }
}

nonisolated struct RewindCommitRequest: Encodable, Sendable {
    let eventID: String
    let startedAt: String?
    let endedAt: String?
    let location: Location?
    let frames: [Frame]
    let metadata: Metadata

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case location
        case frames
        case metadata
    }

    nonisolated struct Location: Encodable, Sendable {
        let latitude: Double
        let longitude: Double
    }

    nonisolated struct Frame: Encodable, Sendable {
        let deviceFrameUUID: String
        let capturedAt: String
        let offsetMs: Int
        let imageBase64: String?
        let mimeType: String?

        enum CodingKeys: String, CodingKey {
            case deviceFrameUUID = "device_frame_uuid"
            case capturedAt = "captured_at"
            case offsetMs = "offset_ms"
            case imageBase64 = "image_base64"
            case mimeType = "mime_type"
        }
    }

    nonisolated struct Metadata: Encodable, Sendable {
        let rewindDurationMs: Int
        let captureAnchorUTC: String
        let captureDurationMs: Int
        let captureWindowStartedAt: String
        let captureWindowEndedAt: String
        let frameEmbeddingMode: String
        let clientTimeZone: String
        let clientUTCOffsetMinutes: Int
        let locationAccuracyMeters: Int?
        let locationCapturedAt: String?

        enum CodingKeys: String, CodingKey {
            case rewindDurationMs = "rewind_duration_ms"
            case captureAnchorUTC = "capture_anchor_utc"
            case captureDurationMs = "capture_duration_ms"
            case captureWindowStartedAt = "capture_window_started_at"
            case captureWindowEndedAt = "capture_window_ended_at"
            case frameEmbeddingMode = "frame_embedding_mode"
            case clientTimeZone = "client_time_zone"
            case clientUTCOffsetMinutes = "client_utc_offset_minutes"
            case locationAccuracyMeters = "location_accuracy_meters"
            case locationCapturedAt = "location_captured_at"
        }
    }
}

nonisolated struct RewindCapturedLocation: Sendable {
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Int
    let capturedAt: Date
}

nonisolated struct RewindSearchRequest: Encodable, Sendable {
    let query: String
    let limit: Int
    let clientContext: RewindSessionHello.Context

    enum CodingKeys: String, CodingKey {
        case query
        case limit
        case clientContext = "client_context"
    }
}
