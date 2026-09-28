import SwiftUI

/// Map, car, recording and diagnostics settings in one place.
struct SettingsView: View {
    @ObservedObject var store: NavigationStore
    @Environment(\.dismiss) private var dismiss

    private var idle: Bool {
        return store.phase == .selecting || store.phase == .paused
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(MapRegion.all) { region in
                        Button {
                            store.selectRegion(region)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(region.name)
                                        .foregroundStyle(Theme.primaryText)
                                    Text(region.summary)
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryText)
                                }
                                Spacer()
                                if region == store.region {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .disabled(!idle)
                    }
                } header: {
                    Text("Map")
                } footer: {
                    Text("Changing the map resets the starting point and route. Only possible while no drive is running.")
                }
                .listRowBackground(Theme.surface)
                Section("Car") {
                    WheelbaseSettings(store: store)
                }
                .listRowBackground(Theme.surface)
                Section("Recording") {
                    GPSTraceSettings(store: store)
                    NavigationLink {
                        DrivesView(store: store) {
                            dismiss()
                        }
                    } label: {
                        Label("Recorded drives", systemImage: "clock.arrow.circlepath")
                    }
                    if let failure = store.recordingFailure {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(Theme.warning)
                    }
                }
                .listRowBackground(Theme.surface)
                Section("Diagnostics") {
                    NavigationLink {
                        SensorDetailsView(store: store)
                    } label: {
                        Label("Sensor details", systemImage: "waveform.path.ecg")
                    }
                }
                .listRowBackground(Theme.surface)
                Section("About") {
                    LabeledContent("Version", value: version)
                    Text(coverageText)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                    Link("Map data © OpenStreetMap contributors (ODbL)", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.footnote)
                    Text("Experimental. Positions and speeds are estimates without GPS; the uncertainty radius is a model estimate, not a guarantee. Free for personal, noncommercial use.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                .listRowBackground(Theme.surface)
                Section {
                    Button("Reset everything", role: .destructive) {
                        store.resetEverything()
                        dismiss()
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationBackground(Theme.background)
        .preferredColorScheme(.dark)
    }

    private var version: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(marketing) (\(build)) · engine \(TrackingEngine.version)"
    }

    private var coverageText: String {
        guard let graph = store.graph else {
            return "\(store.region.name): loading."
        }
        return "\(store.region.name): \(store.region.summary). Map snapshot \(graph.dataset.generated.prefix(10)). Offline roads may not include current closures."
    }
}

/// Live sensor and engine values for field testing.
struct SensorDetailsView: View {
    @ObservedObject var store: NavigationStore

    var body: some View {
        List {
            Section("Speed from road bumps") {
                LabeledContent("Vibration speed", value: vibrationSpeedText)
                LabeledContent("Axle echo strength", value: String(format: "%.1f", store.vibrationSpeed?.echoStrength ?? 0))
                LabeledContent("Speed fixes", value: "\(store.speedCorrectionCount)")
            }
            .listRowBackground(Theme.surface)
            Section("Motion") {
                LabeledContent("Forward acceleration", value: String(format: "%.3f m/s²", store.sample?.forwardAcceleration ?? 0))
                LabeledContent("Lateral acceleration", value: String(format: "%.3f m/s²", store.sample?.lateralAcceleration ?? 0))
                LabeledContent("Turn rate", value: String(format: "%.1f°/s", (store.sample?.yawRate ?? 0) * 180 / .pi))
            }
            .listRowBackground(Theme.surface)
            Section("Position") {
                LabeledContent("Uncertainty", value: store.estimate.map { Format.distance($0.uncertainty) } ?? "—")
                LabeledContent("Road hypothesis mass", value: String(format: "%.0f%%", (store.estimate?.roadProbability ?? 0) * 100))
                LabeledContent("Turn fixes", value: "\(store.estimate?.anchorCount ?? 0)")
            }
            .listRowBackground(Theme.surface)
            Section {
                Text("Speed comes from the delay between the front and rear axles crossing the same bumps; a speed fix counts each time it corrected the inertial speed by 5 km/h or more. Turn fixes count turns matched to the route. Position error grows between turns.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Sensor details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var vibrationSpeedText: String {
        guard let observation = store.vibrationSpeed else {
            return "Not measured"
        }
        if observation.stoppedProbability > 0.9 {
            return "Stopped"
        }
        return String(format: "%.0f ± %.0f km/h", observation.speed * 3.6, observation.uncertainty * 3.6)
    }
}
