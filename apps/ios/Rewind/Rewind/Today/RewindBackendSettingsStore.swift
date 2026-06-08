//
//  RewindBackendSettingsStore.swift
//  Rewind
//
//  Created by Codex on 6/7/26.
//

import Foundation
import Observation
import OSLog

/// Settings-facing adapter for backend address editing and health validation.
///
/// The store persists only health-checked backend URLs. Capture and search clients
/// continue to read `RewindConfiguration.defaultConfiguration`, so newly opened
/// live sessions use the last saved backend address without sharing mutable client state.
@MainActor
@Observable
final class RewindBackendSettingsStore {
    private(set) var configuration: RewindConfiguration
    var backendAddress: String
    private(set) var validationState: BackendValidationState = .idle

    @ObservationIgnored private let urlSession: URLSession
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vogelhaus.Rewind",
        category: "RewindBackendSettingsStore"
    )

    init(
        configuration: RewindConfiguration = .defaultConfiguration,
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.backendAddress = configuration.backendBaseURL.absoluteString
        self.urlSession = urlSession
    }

    var normalizedBackendURL: URL? {
        RewindConfiguration.normalizedBackendURL(from: backendAddress)
    }

    var canValidate: Bool {
        normalizedBackendURL != nil && !validationState.isChecking
    }

    func validateAndSave() async {
        guard let backendURL = normalizedBackendURL else {
            validationState = .failed("Enter an IP address or URL.")
            return
        }

        let candidate = RewindConfiguration(
            backendBaseURL: backendURL,
            userID: configuration.userID,
            deviceID: configuration.deviceID,
            deviceLabel: configuration.deviceLabel
        )

        validationState = .checking
        do {
            try candidate.validateForCurrentRuntime()
            try await RewindProtocolClient(configuration: candidate, urlSession: urlSession).checkHealth()
            RewindConfiguration.persistBackendURL(backendURL)
            configuration = candidate
            backendAddress = backendURL.absoluteString
            validationState = .valid("Connected to \(backendURL.absoluteString).")
            logger.info("Saved Rewind backend URL \(backendURL.absoluteString, privacy: .public)")
        } catch {
            validationState = .failed(error.localizedDescription)
            logger.error("Backend health check failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum BackendValidationState: Equatable {
    case idle
    case checking
    case valid(String)
    case failed(String)

    var isChecking: Bool {
        if case .checking = self {
            return true
        }

        return false
    }
}
