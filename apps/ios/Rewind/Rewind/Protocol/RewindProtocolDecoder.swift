//
//  RewindProtocolDecoder.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

import Foundation

nonisolated enum RewindProtocolDecoder {
    private nonisolated struct Envelope: Decodable {
        let type: String
    }

    private nonisolated struct AgentMessagePayload: Decodable {
        let text: String
    }

    private nonisolated struct ErrorPayload: Decodable {
        let error: String
    }

    nonisolated static func decode(_ data: Data, using decoder: JSONDecoder = JSONDecoder()) throws -> RewindServerMessage {
        let envelope = try decoder.decode(Envelope.self, from: data)
        switch envelope.type {
        case "session.ready":
            return .sessionReady(try decoder.decode(RewindSessionReady.self, from: data))
        case "agent.live_state":
            return .liveState(try decoder.decode(RewindLiveState.self, from: data))
        case "agent.message":
            return .agentMessage(try decoder.decode(AgentMessagePayload.self, from: data).text)
        case "agent.media":
            return .agentMedia(try decoder.decode(RewindAgentMedia.self, from: data))
        case "rewind.save_request":
            return .saveRequest(try decoder.decode(RewindSaveRequest.self, from: data))
        case "rewind.search_started":
            return .searchStarted(try decoder.decode(RewindSearchStarted.self, from: data))
        case "rewind.search_results":
            return .searchResults(try decoder.decode(RewindSearchResults.self, from: data))
        case "error":
            return .error(try decoder.decode(ErrorPayload.self, from: data).error)
        default:
            return .unknown(envelope.type)
        }
    }
}
