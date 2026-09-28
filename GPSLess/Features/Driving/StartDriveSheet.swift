import SwiftUI

/// The short checklist before tracking starts or resumes.
struct StartDriveSheet: View {
    @ObservedObject var store: NavigationStore
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var resuming: Bool {
        return store.phase == .paused
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "car.side.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text(resuming ? "Ready to continue?" : "Ready to drive?")
                            .font(.largeTitle.weight(.bold))
                        Text("Three things before the first metre.")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    VStack(spacing: 0) {
                        ChecklistRow(symbol: "parkingsign.circle.fill", title: "Parked where the arrow is",
                                     detail: "On the selected road, facing the arrow's direction.")
                        Divider().overlay(Theme.stroke)
                        ChecklistRow(symbol: "iphone.gen3", title: "Phone upright in a rigid mount",
                                     detail: "Portrait, top edge up, screen facing straight back along the car. A backward tilt is fine; never lay it flat.")
                        Divider().overlay(Theme.stroke)
                        if store.hasCompletedAppCalibration {
                            ChecklistRow(symbol: "checkmark.seal.fill", title: "Calibration reused",
                                         detail: "Keep the same mount. If it moved, restart the app first.")
                        } else {
                            ChecklistRow(symbol: "hand.raised.fill", title: "Hands off for 4 seconds",
                                         detail: "After you press Start the app measures the mount, then you can drive.")
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    SettingsGroup(title: "Car") {
                        WheelbaseSettings(store: store)
                    }
                    SettingsGroup(title: "Testing") {
                        GPSTraceSettings(store: store)
                    }
                    Label("Tracking keeps running in other apps and with the screen locked while Location is allowed. Pause before taking the phone out of the mount.",
                          systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(Theme.tertiaryText)
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onConfirm()
                } label: {
                    Label(resuming ? "Resume drive" : "Start drive", systemImage: resuming ? "play.fill" : "arrow.up.right")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("confirmMount")
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Theme.background.opacity(0.96))
            }
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
        .preferredColorScheme(.dark)
        .onAppear {
            store.prepareBackgroundTracking()
        }
    }
}

private struct ChecklistRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

/// A titled rounded group outside a List.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.tertiaryText)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

/// Wheelbase value and automatic refinement.
struct WheelbaseSettings: View {
    @ObservedObject var store: NavigationStore

    private var editable: Bool {
        return store.phase == .selecting || store.phase == .paused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper(value: $store.wheelbaseMetres, in: VehicleSpeedObserver.supportedWheelbase, step: 0.01) {
                LabeledContent("Wheelbase", value: String(format: "%.2f m", store.wheelbaseMetres))
            }
            .disabled(!editable)
            .accessibilityIdentifier("wheelbaseStepper")
            Text("Front-to-rear axle distance from your car's specifications. Speed and distance scale with it.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
            Toggle("Refine from route turns", isOn: $store.refinesWheelbaseAutomatically)
                .disabled(!editable)
                .accessibilityIdentifier("wheelbaseRefinementToggle")
            Text(learningText)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var learningText: String {
        let evidence = store.wheelbaseEvidence
        guard let estimate = evidence.estimate, let uncertainty = evidence.relativeUncertainty else {
            return "Learns from the mapped distance between matched turns. Changing the value by hand restarts learning."
        }
        let turns = evidence.intervals == 1 ? "1 turn interval" : "\(evidence.intervals) turn intervals"
        if evidence.isConfident {
            return String(format: "Measured %.2f m ±%.1f%% from %@.", estimate, uncertainty * 100, turns)
        }
        return String(format: "Learning: %.2f m ±%.1f%% from %@; applied once within ±1.5%%.", estimate, uncertainty * 100, turns)
    }
}

/// Optional GPS reference trace for accuracy testing.
struct GPSTraceSettings: View {
    @ObservedObject var store: NavigationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Use GPS tracing", isOn: Binding(get: {
                return store.gpsTrace.isEnabled
            }, set: { enabled in
                store.gpsTrace.isEnabled = enabled
            }))
            .disabled(store.phase != .selecting && store.phase != .paused)
            .accessibilityIdentifier("gpsTraceToggle")
            Text("Saves GPS reference data with this ride for later analysis. Positioning never uses it.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
            Text(store.gpsTrace.statusText)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityIdentifier("gpsTraceSettingsStatus")
        }
    }
}
