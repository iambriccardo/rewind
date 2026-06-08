//
//  RewindConfiguration.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

import Foundation

/// Runtime configuration for the local Rewind protocol client.
///
/// The backend URL intentionally defaults to a non-routable documentation address.
/// Local development devices must opt in to the actual Mac LAN address from Settings,
/// which keeps accidental localhost assumptions out of physical-device builds.
nonisolated struct RewindConfiguration: Sendable {
    nonisolated static let backendURLDefaultsKey = "REWIND_BACKEND_URL"
    nonisolated static let defaultBackendURLString = "http://192.0.2.1:8787"
    nonisolated static let defaultBackendPort = 8787

    var backendBaseURL: URL
    var userID: String
    var deviceID: String
    var deviceLabel: String

    nonisolated static var defaultConfiguration: RewindConfiguration {
        let infoDictionary = Bundle.main.infoDictionary ?? [:]
        let backendURLString = Self.value(
            for: backendURLDefaultsKey,
            in: infoDictionary,
            defaultValue: defaultBackendURLString
        )
        let userID = Self.value(
            for: "REWIND_DEV_USER_ID",
            in: infoDictionary,
            defaultValue: "00000000-0000-4000-8000-000000000001"
        )
        let deviceID = Self.value(
            for: "REWIND_DEV_DEVICE_ID",
            in: infoDictionary,
            defaultValue: "dev-phone"
        )
        let deviceLabel = Self.value(
            for: "REWIND_DEVICE_LABEL",
            in: infoDictionary,
            defaultValue: "Rewind iPhone"
        )

        return RewindConfiguration(
            backendBaseURL: Self.validBackendURL(from: backendURLString),
            userID: userID,
            deviceID: deviceID,
            deviceLabel: deviceLabel
        )
    }

    nonisolated static let localDevelopment = RewindConfiguration(
        backendBaseURL: URL(string: "http://localhost:8787")!,
        userID: "00000000-0000-4000-8000-000000000001",
        deviceID: "dev-phone",
        deviceLabel: "Rewind iPhone"
    )

    nonisolated var liveWebSocketURL: URL {
        var components = URLComponents(url: backendBaseURL, resolvingAgainstBaseURL: false)!
        components.scheme = backendBaseURL.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/live"
        components.queryItems = [
            URLQueryItem(name: "user_id", value: userID),
            URLQueryItem(name: "device_id", value: deviceID)
        ]
        return components.url!
    }

    nonisolated func httpURL(path: String) -> URL {
        URL(string: path, relativeTo: backendBaseURL)!.absoluteURL
    }

    nonisolated func validateForCurrentRuntime() throws {
#if os(iOS) && !targetEnvironment(simulator)
        if Self.isLoopback(backendBaseURL) {
            throw RewindConfigurationError.physicalDeviceLoopbackBackend
        }
#endif
    }

    private nonisolated static func value(
        for key: String,
        in infoDictionary: [String: Any],
        defaultValue: String
    ) -> String {
        if let launchArgumentValue = launchArgumentValue(for: key), !launchArgumentValue.isEmpty {
            return launchArgumentValue
        }

        if let launchArgumentValue = UserDefaults.standard.string(forKey: key), !launchArgumentValue.isEmpty {
            return launchArgumentValue
        }

        if let environmentValue = ProcessInfo.processInfo.environment[key], !environmentValue.isEmpty {
            return environmentValue
        }

        if let infoValue = infoDictionary[key] as? String, !infoValue.isEmpty {
            return infoValue
        }

        return defaultValue
    }

    private nonisolated static func launchArgumentValue(for key: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        let keyForms = [
            key,
            "-\(key)",
            "--\(key)"
        ]

        for index in arguments.indices {
            let argument = arguments[index]

            for keyForm in keyForms {
                if argument == keyForm, arguments.indices.contains(arguments.index(after: index)) {
                    return arguments[arguments.index(after: index)]
                }

                let prefix = "\(keyForm)="
                if argument.hasPrefix(prefix) {
                    return String(argument.dropFirst(prefix.count))
                }
            }
        }

        return nil
    }

    nonisolated static func validBackendURL(from value: String) -> URL {
        let configuredURL = normalizedBackendURL(from: value) ?? URL(string: defaultBackendURLString)!
#if os(iOS) && !targetEnvironment(simulator)
        if isLoopback(configuredURL) {
            return URL(string: defaultBackendURLString)!
        }
#endif
        return configuredURL
    }

    /// Normalizes a Settings-entered backend address into the URL used by HTTP and WebSocket clients.
    ///
    /// Users can enter either a full `http://host:port` URL or a bare IP/host. Bare
    /// values default to `http` on the Rewind development backend port.
    nonisolated static func normalizedBackendURL(from value: String) -> URL? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return nil
        }

        let candidate = trimmedValue.contains("://") ? trimmedValue : "http://\(trimmedValue)"
        guard var components = URLComponents(string: candidate) else {
            return nil
        }

        guard components.scheme == "http" || components.scheme == "https", components.host != nil else {
            return nil
        }

        if components.port == nil {
            components.port = defaultBackendPort
        }

        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    nonisolated static func persistBackendURL(_ url: URL, userDefaults: UserDefaults = .standard) {
        userDefaults.set(url.absoluteString, forKey: backendURLDefaultsKey)
    }

    private nonisolated static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }

        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }
}

nonisolated enum RewindConfigurationError: LocalizedError {
    case physicalDeviceLoopbackBackend

    nonisolated var errorDescription: String? {
        switch self {
        case .physicalDeviceLoopbackBackend:
            "Set the iPhone build's REWIND_BACKEND_URL Info.plist value to the Mac LAN backend URL. A physical iPhone cannot connect to the Mac through localhost."
        }
    }
}
