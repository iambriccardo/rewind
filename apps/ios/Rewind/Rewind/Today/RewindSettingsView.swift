//
//  RewindSettingsView.swift
//  Rewind
//
//  Created by Codex on 6/7/26.
//

import SwiftUI

/// MVP settings for checking configuration and clearing local device memory.
struct RewindSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var backendSettings = RewindBackendSettingsStore()
    @State private var cacheSummary: CaptureFrameCacheSummary = .empty
    @State private var isLoadingCacheSummary = false
    @State private var isDeletingCache = false
    @State private var cacheDeletionError: String?
    @State private var isDeleteConfirmationPresented = false

    private let frameCache = CaptureFrameCache.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Backend address", text: $backendSettings.backendAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#if os(iOS)
                        .keyboardType(.URL)
#endif

                    LabeledContent("Backend", value: backendSettings.configuration.backendBaseURL.absoluteString)
                    LabeledContent("Live socket", value: backendSettings.configuration.liveWebSocketURL.absoluteString)

                    Button {
                        Task {
                            await backendSettings.validateAndSave()
                        }
                    } label: {
                        if backendSettings.validationState.isChecking {
                            ProgressView()
                        } else {
                            Label("Check Connection", systemImage: "network")
                        }
                    }
                    .disabled(!backendSettings.canValidate)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Enter your Mac IP address or backend URL. Rewind checks /health before saving. If no port is entered, it uses 8787.")
                }

                connectionValidationSection

                Section("Device") {
                    LabeledContent("Label", value: backendSettings.configuration.deviceLabel)
                    LabeledContent("Device ID", value: backendSettings.configuration.deviceID)
                    LabeledContent("User ID", value: backendSettings.configuration.userID)
                }

                Section {
                    if isLoadingCacheSummary {
                        HStack {
                            Text("Refreshing")
                            Spacer()
                            ProgressView()
                        }
                    }

                    LabeledContent("Images", value: cacheSummary.imageCount.formatted())
                    LabeledContent("Storage", value: formattedByteCount(cacheSummary.byteCount))
                    LabeledContent("Days", value: cacheSummary.dayCount.formatted())

                    Button(role: .destructive) {
                        isDeleteConfirmationPresented = true
                    } label: {
                        if isDeletingCache {
                            ProgressView()
                        } else {
                            Label("Delete Cached Images", systemImage: "trash")
                        }
                    }
                    .disabled(cacheSummary.isEmpty || isDeletingCache)
                } header: {
                    Text("Device Memory")
                } footer: {
                    Text("Deletes local cached capture images from this device. Backend memories and metadata are not deleted.")
                }

                if let cacheDeletionError {
                    Section {
                        Label(cacheDeletionError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await refreshCacheSummary()
            }
            .refreshable {
                await refreshCacheSummary()
            }
            .alert("Delete cached images?", isPresented: $isDeleteConfirmationPresented) {
                Button("Delete", role: .destructive) {
                    Task {
                        await deleteCachedImages()
                    }
                }

                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes \(cacheSummary.imageCount.formatted()) cached images from this device. Saved backend memories are not deleted.")
            }
        }
    }

    @ViewBuilder
    private var connectionValidationSection: some View {
        switch backendSettings.validationState {
        case .idle, .checking:
            EmptyView()
        case let .valid(message):
            Section {
                Label(message, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        case let .failed(message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }

    private func refreshCacheSummary() async {
        isLoadingCacheSummary = true
        cacheSummary = await frameCache.cacheSummary()
        isLoadingCacheSummary = false
    }

    private func deleteCachedImages() async {
        isDeletingCache = true
        cacheDeletionError = nil
        defer {
            isDeletingCache = false
        }

        do {
            try await frameCache.deleteAllFrames()
            MemoryImage.clearFileCache()
            await refreshCacheSummary()
        } catch {
            cacheDeletionError = error.localizedDescription
        }
    }

    private func formattedByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

#Preview("Settings") {
    RewindSettingsView()
}
