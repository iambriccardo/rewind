//
//  RewindLocationProvider.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

#if os(iOS)
import CoreLocation
import Foundation
import OSLog

/// Best-effort location reader used only when committing a backend save request.
///
/// The live protocol does not need continuous location. This provider mirrors the
/// web phone client by asking for one recent fix during `rewind.save_request` and
/// returning `nil` quickly when permission or hardware is unavailable.
@MainActor
final class RewindLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vogelhaus.Rewind",
        category: "RewindLocation"
    )

    private var authorizationContinuation: CheckedContinuation<Bool, Never>?
    private var authorizationTimeoutTask: Task<Void, Never>?
    private var locationContinuation: CheckedContinuation<RewindCapturedLocation?, Never>?
    private var locationTimeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation(timeout: Duration = .milliseconds(1_500), maximumAge: TimeInterval = 60) async -> RewindCapturedLocation? {
        if let cachedLocation = manager.location,
           abs(cachedLocation.timestamp.timeIntervalSinceNow) <= maximumAge {
            return Self.location(from: cachedLocation)
        }

        guard await ensureAuthorized(timeout: timeout) else {
            logger.info("Location permission is unavailable")
            return nil
        }

        return await requestLocation(timeout: timeout)
    }

    private func ensureAuthorized(timeout: Duration) async -> Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                authorizationContinuation = continuation
                authorizationTimeoutTask?.cancel()
                authorizationTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.finishAuthorization(false)
                }
                manager.requestWhenInUseAuthorization()
            }
        @unknown default:
            return false
        }
    }

    private func requestLocation(timeout: Duration) async -> RewindCapturedLocation? {
        await withCheckedContinuation { continuation in
            locationContinuation = continuation
            locationTimeoutTask?.cancel()
            locationTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishLocation(nil)
            }
            manager.requestLocation()
        }
    }

    private func finishAuthorization(_ authorized: Bool) {
        authorizationTimeoutTask?.cancel()
        authorizationTimeoutTask = nil
        authorizationContinuation?.resume(returning: authorized)
        authorizationContinuation = nil
    }

    private func finishLocation(_ location: RewindCapturedLocation?) {
        locationTimeoutTask?.cancel()
        locationTimeoutTask = nil
        locationContinuation?.resume(returning: location)
        locationContinuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                self?.finishAuthorization(true)
            case .denied, .restricted:
                self?.finishAuthorization(false)
            case .notDetermined:
                break
            @unknown default:
                self?.finishAuthorization(false)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            Task { @MainActor [weak self] in
                self?.finishLocation(nil)
            }
            return
        }

        let capturedLocation = Self.location(from: location)
        Task { @MainActor [weak self] in
            self?.logger.info(
                "Location ready with \(capturedLocation.accuracyMeters, privacy: .public)m accuracy"
            )
            self?.finishLocation(capturedLocation)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.logger.error("Location request failed: \(error.localizedDescription, privacy: .public)")
            self?.finishLocation(nil)
        }
    }

    private nonisolated static func location(from location: CLLocation) -> RewindCapturedLocation {
        RewindCapturedLocation(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracyMeters: Int(max(0, location.horizontalAccuracy.rounded())),
            capturedAt: location.timestamp
        )
    }
}
#endif
