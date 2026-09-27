import SwiftUI

struct DrivingScreen: View {
    @ObservedObject var store: NavigationStore
    @State private var showMount = false
    @State private var showSatellite = false
    /// The satellite map stays mounted after first use so it can be aligned
    /// and rendered before it fades in.
    @State private var satelliteMounted = false
    @State private var satelliteRevealRequest = 0
    @State private var satelliteRevealPending = false
    @State private var showDrives = false
    @State private var showDiagnostics = false
    @State private var showSearch = false
    @State private var satelliteStatus = "Loading online imagery…"

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()
            OfflineMapView(store: store, bottomInset: 150, isActive: !showSatellite)
                .ignoresSafeArea()
            if satelliteMounted {
                SatelliteSelectionMap(store: store, imageryStatus: $satelliteStatus, isVisible: showSatellite,
                                      revealRequest: satelliteRevealRequest) {
                    guard satelliteRevealPending else {
                        return
                    }
                    satelliteRevealPending = false
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showSatellite = true
                    }
                }
                .ignoresSafeArea()
                .opacity(showSatellite ? 1 : 0)
                .allowsHitTesting(showSatellite)
                .accessibilityHidden(!showSatellite)
                .zIndex(1)
            }
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                HStack {
                    Spacer()
                    satelliteButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                Spacer()
                contextualControls
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
            .zIndex(2)
        }
        .tint(AppColors.accent)
        .fullScreenCover(isPresented: $showMount) {
            mountSheet
        }
        .sheet(isPresented: $showDrives) {
            DrivesSheet(store: store)
        }
        .sheet(isPresented: $showDiagnostics) {
            diagnostics
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSearch) {
            PlaceSearchView(store: store, usesAppleMaps: showSatellite)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .foregroundStyle(AppColors.accent)
                Text("GPSLess")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer()
            Button {
                showSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 42, height: 42)
            }
            .disabled(store.placeSearch == nil || store.phase == .tracking || store.phase == .calibrating || store.phase == .replaying)
            .accessibilityLabel("Search places and streets")
            .accessibilityIdentifier("openSearch")
            Menu {
                Button {
                    showDrives = true
                } label: {
                    Label("Recorded drives", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    showDiagnostics = true
                } label: {
                    Label("Sensor details", systemImage: "waveform.path.ecg")
                }
                if store.selection != nil || store.estimate != nil {
                    Button {
                        store.recenter()
                    } label: {
                        Label("Center map", systemImage: "scope")
                    }
                }
                Menu {
                    Picker("Map region", selection: Binding(get: {
                        return store.region.id
                    }, set: { id in
                        store.selectRegion(MapRegion.named(id))
                    })) {
                        ForEach(MapRegion.all) { region in
                            Text(region.name).tag(region.id)
                        }
                    }
                } label: {
                    Label("Map region · \(store.region.name)", systemImage: "map")
                }
                .disabled(store.phase != .selecting && store.phase != .paused)
                .accessibilityIdentifier("mapRegion")
                Button(role: .destructive) {
                    store.resetEverything()
                } label: {
                    Label("Reset everything", systemImage: "arrow.counterclockwise")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 42, height: 42)
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(AppColors.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 22))
        .foregroundStyle(.white)
    }

    private var satelliteButton: some View {
        Button {
            if showSatellite || satelliteRevealPending {
                satelliteRevealPending = false
                withAnimation(.easeInOut(duration: 0.3)) {
                    showSatellite = false
                }
            } else {
                // Align and render first; the satellite map calls back to fade in.
                satelliteMounted = true
                satelliteRevealPending = true
                satelliteRevealRequest += 1
            }
        } label: {
            Image(systemName: showSatellite || satelliteRevealPending ? "map.fill" : "globe.europe.africa.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(MapControlStyle())
        .accessibilityLabel(showSatellite ? "Show offline map" : "Show satellite map")
        .accessibilityIdentifier("openSatellite")
    }

    @ViewBuilder
    private var contextualControls: some View {
        if store.phase == .loading {
            compactCard {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading \(store.region.name) map")
                }
            }
        } else if store.phase == .selecting {
            selectionControls
        } else if store.phase == .calibrating {
            compactCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Keep the phone still")
                        .font(.headline)
                    ProgressView(value: store.calibrationProgress)
                        .tint(AppColors.accent)
                    Button("Cancel") {
                        store.pause()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        } else if store.phase == .tracking {
            compactCard {
                VStack(spacing: 12) {
                    trackingMetrics
                    if let hint = store.speedCorrectionHint {
                        Label(hint, systemImage: "waveform.path")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppColors.accent)
                            .transition(.opacity)
                            .accessibilityIdentifier("speedCorrectionHint")
                    }
                    Button {
                        store.pause()
                    } label: {
                        Label("I need the phone", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("pauseTracking")
                    Button("Car is stopped · reset speed") {
                        store.confirmStop()
                    }
                    .font(.system(size: 12, weight: .medium))
                }
            }
        } else if store.phase == .replaying {
            compactCard {
                VStack(spacing: 12) {
                    ProgressView(value: store.replayProgress)
                    Button("Cancel replay") {
                        store.setPositionAgain()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        } else {
            compactCard {
                VStack(spacing: 12) {
                    Text(store.message)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondary)
                        .accessibilityIdentifier("trackingMessage")
                    if store.canResumeHere && store.routeOptions.count > 1 {
                        routeOptionList
                    }
                    Button("Set current position") {
                        store.setPositionAgain()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("setPosition")
                    if store.canResumeHere {
                        Button("Car stayed here · resume") {
                            showMount = true
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        if store.selectedRoute != nil && store.routeOptions.isEmpty {
                            Button(store.planningRoute ? "Finding routes…" : "Change route from here") {
                                store.changeRouteFromHere()
                            }
                            .font(.footnote)
                            .disabled(store.planningRoute)
                            .accessibilityIdentifier("changeRoute")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var selectionControls: some View {
        if store.selection == nil {
            compactPrompt("Tap a road to set your starting point", symbol: "mappin")
                .accessibilityIdentifier("startingPointRequest")
        } else if store.planningRoute {
            compactPrompt("Finding route…", symbol: "point.topleft.down.to.point.bottomright.curvepath")
        } else if store.routeLocked, let route = store.selectedRoute, let graph = store.graph {
            compactCard {
                VStack(spacing: 12) {
                    if store.routeOptions.count > 1 {
                        routeOptionList
                    } else {
                        Text(String(format: "Route ready · %.1f km", route.distance(in: graph) / 1000))
                            .font(.headline)
                    }
                    Button {
                        showMount = true
                    } label: {
                        Label("Start", systemImage: "arrow.up.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!store.mapReady)
                    .accessibilityIdentifier("startTracking")
                    Button("Reset everything") {
                        store.resetEverything()
                    }
                    .font(.footnote)
                    .accessibilityIdentifier("resetEverything")
                }
            }
        } else if store.choosingDestination {
            compactPrompt(store.message, symbol: "flag.checkered")
                .accessibilityIdentifier("destinationPointRequest")
        } else {
            compactCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(store.roadName)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        Button {
                            store.reverseDirection()
                        } label: {
                            Label("Flip direction", systemImage: "arrow.up.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!store.canReverse)
                        .accessibilityIdentifier("flipDirection")
                        Text(compassDirection)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .frame(width: 42)
                    }
                    Button {
                        store.chooseDestination()
                    } label: {
                        Text("Confirm")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("confirmStartingPoint")
                }
            }
        }
    }

    /// Offered routes, fastest first; the chosen one is drawn in cyan.
    private var routeOptionList: some View {
        VStack(spacing: 6) {
            ForEach(Array(store.routeOptions.enumerated()), id: \.offset) { index, option in
                Button {
                    store.chooseRoute(index)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: index == store.selectedRouteIndex ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(index == store.selectedRouteIndex ? Color.cyan : AppColors.secondary)
                        Text(option.label)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(String(format: "%.1f km · %@", option.metres / 1000, duration(option.seconds)))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(AppColors.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(index == store.selectedRouteIndex ? 0.10 : 0.03), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("routeOption\(index)")
            }
            Text("Times assume typical free-flow speeds for each road type.")
                .font(.caption2)
                .foregroundStyle(AppColors.secondary)
        }
    }

    private func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "\(max(1, minutes)) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    private func compactPrompt(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(AppColors.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(AppColors.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 22))
            .foregroundStyle(.white)
    }

    private var trackingMetrics: some View {
        HStack {
            metric("EST. SPEED", value: "\(Int((store.estimate?.speed ?? 0) * 3.6))", unit: "km/h")
            Spacer()
            metric("UNCERTAINTY", value: "±\(Int(store.estimate?.uncertainty ?? 0))", unit: "m")
            Spacer()
            metric("TURN FIXES", value: "\(store.estimate?.anchorCount ?? 0)", unit: "")
            Spacer()
            metric("SPEED FIXES", value: "\(store.speedCorrectionCount)", unit: "")
                .accessibilityIdentifier("speedCorrectionCount")
        }
        .padding(.vertical, 5)
        .animation(.easeInOut(duration: 0.25), value: store.speedCorrectionHint)
    }

    private func metric(_ label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(AppColors.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 23, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundStyle(AppColors.secondary)
            }
        }
    }

    private var mountSheet: some View {
        ScrollView {
            mountInstructions
        }
        .background(AppColors.panel)
        .onAppear {
            store.prepareBackgroundTracking()
        }
    }

    private var mountInstructions: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 35))
                .foregroundStyle(AppColors.accent)
            if store.hasCompletedAppCalibration {
                Text("Park. Mount. Start.")
                    .font(.system(size: 27, weight: .semibold))
            } else {
                Text("Park. Mount. Calibrate.")
                    .font(.system(size: 27, weight: .semibold))
            }
            Text("Stop the car on the selected road. Check that the map arrow points in the car’s forward direction.")
            Text("Secure the phone in portrait, top edge up. The screen must face straight back along the car, not sideways toward you. A slight backward tilt is fine; do not lay it flat.")
            if store.hasCompletedAppCalibration {
                Text("This app session’s calibration will be reused. Keep the phone in the same mount and drive forward. If the mount changed, reopen the app before testing.")
                    .foregroundStyle(AppColors.secondary)
            } else {
                Text("Keep it untouched for 4 seconds, then drive forward. If the car moves while tracking is paused, set a new position before resuming.")
                    .foregroundStyle(AppColors.secondary)
            }
            Text("You can switch to another app or lock the screen while driving; tracking continues when Location is allowed. Pause before taking the phone out of the mount.")
                .foregroundStyle(AppColors.secondary)
            wheelbaseSettings
            gpsTraceSettings
            Button {
                showMount = false
                store.start()
            } label: {
                Text("Car stopped & phone mounted")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("confirmMount")
        }
        .font(.system(size: 15))
        .padding(26)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppColors.panel)
    }

    private var diagnostics: some View {
        NavigationStack {
            List {
                Section("Vehicle") {
                    wheelbaseSettings
                }
                Section("Field testing") {
                    gpsTraceSettings
                    if let failure = store.recordingFailure {
                        Text(failure)
                            .foregroundStyle(.orange)
                    }
                }
                Section("Live motion") {
                    LabeledContent("Forward acceleration", value: String(format: "%.3f m/s²", store.sample?.forwardAcceleration ?? 0))
                    LabeledContent("Lateral acceleration", value: String(format: "%.3f m/s²", store.sample?.lateralAcceleration ?? 0))
                    LabeledContent("Turn rate", value: String(format: "%.1f°/s", (store.sample?.yawRate ?? 0) * 180 / .pi))
                    LabeledContent("Road hypothesis mass", value: String(format: "%.0f%%", (store.estimate?.roadProbability ?? 0) * 100))
                    LabeledContent("Vibration speed", value: vibrationSpeedText)
                    LabeledContent("Axle echo strength", value: String(format: "%.1f", store.vibrationSpeed?.echoStrength ?? 0))
                    LabeledContent("Speed fixes from bumps", value: "\(store.speedCorrectionCount)")
                }
                Section("How to read this") {
                    Text("Speed comes from the delay between the front and rear axles crossing the same road bumps; a speed fix counts each time that measurement corrected the inertial speed by 5 km/h or more. Turn fixes count turns matched to the route. Position error grows between turns; the uncertainty radius is a model estimate, not a verified accuracy guarantee.")
                    Text("Pause before taking the phone out of the mount. Reversing requires stopping and setting position again.")
                }
                Section("Offline map") {
                    Text(coverageText)
                    Text("OpenStreetMap data © contributors, ODbL 1.0. Offline geometry may not include current closures. This prototype does not provide directions.")
                    Link("OpenStreetMap copyright and licence", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                }
            }
            .navigationTitle("Tracking details")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var coverageText: String {
        guard let graph = store.graph else {
            return "\(store.region.name): loading."
        }
        let bounds = graph.dataset.bounds
        return String(format: "%@ (%@): %.2f–%.2f° N, %.2f–%.2f° E. The orange outline marks its boundary. Snapshot: %@. Change it from More → Map region while no drive is active.",
                      store.region.name, store.region.summary, bounds[0], bounds[2], bounds[1], bounds[3], graph.dataset.generated)
    }

    private var wheelbaseSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper(value: $store.wheelbaseMetres, in: VehicleSpeedObserver.supportedWheelbase, step: 0.01) {
                LabeledContent("Car wheelbase", value: String(format: "%.2f m", store.wheelbaseMetres))
            }
            .disabled(store.phase != .selecting && store.phase != .paused)
            .accessibilityIdentifier("wheelbaseStepper")
            Text("Distance between the front and rear axle centres, from your car’s specifications. Speed is measured from the delay between the axles crossing the same bumps, so an error here scales speed and distance.")
                .font(.footnote)
                .foregroundStyle(AppColors.secondary)
            Toggle("Refine from route turns", isOn: $store.refinesWheelbaseAutomatically)
                .disabled(store.phase != .selecting && store.phase != .paused)
                .accessibilityIdentifier("wheelbaseRefinementToggle")
            Text(wheelbaseLearningText)
                .font(.footnote)
                .foregroundStyle(AppColors.secondary)
        }
    }

    private var wheelbaseLearningText: String {
        let evidence = store.wheelbaseEvidence
        guard let estimate = evidence.estimate, let uncertainty = evidence.relativeUncertainty else {
            return "Learns from the mapped distance between matched turns on a locked route. Changing the value by hand restarts learning."
        }
        let turns = evidence.intervals == 1 ? "1 turn interval" : "\(evidence.intervals) turn intervals"
        if evidence.isConfident {
            return String(format: "Measured %.2f m ±%.1f%% from %@.", estimate, uncertainty * 100, turns)
        }
        return String(format: "Learning: %.2f m ±%.1f%% from %@; applied once within ±1.5%%.", estimate, uncertainty * 100, turns)
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

    private var gpsTraceSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Use GPS tracing", isOn: Binding(get: {
                return store.gpsTrace.isEnabled
            }, set: { enabled in
                store.gpsTrace.isEnabled = enabled
            }))
            .disabled(store.phase != .selecting && store.phase != .paused)
            .accessibilityIdentifier("gpsTraceToggle")
            Text("Saves GPS reference data with this ride for later analysis. Positioning never uses it.")
                .font(.footnote)
                .foregroundStyle(AppColors.secondary)
            Text(store.gpsTrace.statusText)
                .font(.footnote)
                .foregroundStyle(AppColors.secondary)
                .accessibilityIdentifier("gpsTraceSettingsStatus")
        }
    }

    private var compassDirection: String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((store.heading + 2 * .pi + .pi / 8) / (.pi / 4)) % 8
        return directions[max(0, index)]
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(AppColors.background)
            .frame(minHeight: 54)
            .padding(.horizontal, 16)
            .background(AppColors.accent, in: RoundedRectangle(cornerRadius: 16))
            .opacity(opacity(configuration.isPressed))
    }

    private func opacity(_ pressed: Bool) -> Double {
        if !isEnabled {
            return 0.4
        }
        if pressed {
            return 0.75
        }
        return 1
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(minHeight: 44)
            .padding(.horizontal, 12)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MapControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(AppColors.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
    }
}
