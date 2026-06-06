//
//  TodaySettings.swift
//  Rewind
//
//  Created by Codex on 6/6/26.
//

import SwiftUI

/// Settings actions for the Today timeline.
struct TodaySettings: View {
    @Environment(\.dismiss) private var dismiss

    let openCaptureMode: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        dismiss()
                        openCaptureMode()
                    } label: {
                        Label("Capture Mode", systemImage: "camera.viewfinder")
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    TodaySettings {}
}
