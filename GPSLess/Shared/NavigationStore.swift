import Combine
import SwiftUI

enum DrivePhase: String {
    case loading
    case selecting
    case calibrating
    case tracking
    case paused
    case replaying
}

struct NavigationMapViewport: Equatable {
    let center: Coordinate
    let latitudeDelta: Double
    let longitudeDelta: Double
}

@MainActor
final class NavigationStore: ObservableObject {
    @Published var phase: DrivePhase = .loading
    @Published var graph: RoadGraph?
    @Published var selection: RoadPosition?
    @Published private(set) var selectedRoute: SelectedRoute? {
        didSet {
            if let selectedRoute, let graph {
                routeIndex = RouteIndex(route: selectedRoute, graph: graph)
            } else {
                routeIndex = nil
            }
        }
    }
    /// Planned driving time and name of the chosen route's destination.
    @Published private(set) var plannedRouteSeconds: Double?
    @Published private(set) var destinationName: String?
    private var pendingDestinationName: String?
    @Published private(set) var routeOverviewRequest = 0
    private var routeIndex: RouteIndex?
    /// Offered routes between A and B; the chosen one is `selectedRoute`.
    @Published private(set) var routeOptions: [RouteOption] = []
    @Published private(set) var selectedRouteIndex = 0
    @Published private(set) var placeSearch: PlaceSearch?
    /// A coordinate the map should show, e.g. a search result.
    @Published private(set) var mapFocus: Coordinate?
    @Published private(set) var mapFocusRequest = 0
    @Published private(set) var routeLocked = false
    @Published private(set) var choosingDestination = false
    @Published private(set) var planningRoute = false
    /// Why the last tap or search result could not become point A or B, or
    /// why no route was found; shown on the planning card until the next try.
    @Published private(set) var selectionProblem: String?
    /// A place shared from another maps app before the map finished loading.
    private var pendingSharedPlace: SharedPlace?
    /// Counts places that arrived by link from the share sheet, so the screen
    /// can close the search or settings sheet that would hide them.
    @Published private(set) var sharedPlaceArrivals = 0
    private var routeGeneration = UUID()
    @Published var estimate: TrackingEstimate?
    @Published var sample: MotionSample?
    @Published var message = "Preparing the offline map"
    @Published var calibrationProgress = 0.0
    @Published var trail: [Coordinate] = []
    @Published var follow = false
    @Published var cameraRequest = 0
    @Published var lastRecording: URL?
    @Published var replayProgress = 0.0
    @Published var mapReady = false
    @Published var mapViewport: NavigationMapViewport?
    @Published var canResumeHere = false
    @Published var recordingFailure: String?
    @Published var recordingBytes = 0
    let gpsTrace = GPSReferenceService()
    private let motion = MotionTrackingService()
    private let background = BackgroundTrackingService()
    private var watchdog: Timer?
    private var lastSensorReport = Date()
    private var replayGeneration = UUID()
    private var replayTask: Task<Void, Never>?
    private var showingReplay = false
    private var gpsCancellable: AnyCancellable?
    @Published private(set) var hasCompletedAppCalibration = false
    @Published private(set) var vibrationSpeed: VibrationSpeedObservation?
    /// Road-bump speed corrections this drive and a short-lived description of the latest.
    @Published private(set) var speedCorrectionCount = 0
    @Published private(set) var speedCorrectionHint: String?
    private var speedHintGeneration = 0
    /// Front-to-rear axle distance of the car. Vibration speed scales with it,
    /// so a changed value also requires a new parked calibration.
    @Published var wheelbaseMetres: Double {
        didSet {
            UserDefaults.standard.set(wheelbaseMetres, forKey: Self.wheelbaseKey)
            // A manual change means another car or a deliberate override.
            if oldValue != wheelbaseMetres && !applyingLearnedWheelbase {
                wheelbaseEvidence = WheelbaseEvidence()
            }
        }
    }
    private static let wheelbaseKey = "vehicleWheelbaseMetres"
    /// Wheelbase learned from mapped distances between matched route turns,
    /// pooled across drives.
    @Published private(set) var wheelbaseEvidence: WheelbaseEvidence {
        didSet {
            if let data = try? JSONEncoder().encode(wheelbaseEvidence) {
                UserDefaults.standard.set(data, forKey: Self.evidenceKey)
            }
        }
    }
    @Published var refinesWheelbaseAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(refinesWheelbaseAutomatically, forKey: Self.refinesKey)
        }
    }
    private var applyingLearnedWheelbase = false
    private static let evidenceKey = "wheelbaseEvidence"
    private static let refinesKey = "refinesWheelbaseAutomatically"
    /// The bundled offline map in use. Changing it reloads the road graph.
    @Published private(set) var region: MapRegion
    private static let regionKey = "mapRegion"

    init() {
        let storedWheelbase = UserDefaults.standard.double(forKey: Self.wheelbaseKey)
        wheelbaseMetres = VehicleSpeedObserver.supportedWheelbase.contains(storedWheelbase) ? storedWheelbase : VehicleSpeedObserver.defaultWheelbase
        // UI tests are written against the Kyiv map whatever was used last.
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            region = .kyiv
        } else {
            region = MapRegion.named(UserDefaults.standard.string(forKey: Self.regionKey))
        }
        wheelbaseEvidence = UserDefaults.standard.data(forKey: Self.evidenceKey).flatMap { data in
            return try? JSONDecoder().decode(WheelbaseEvidence.self, from: data)
        } ?? WheelbaseEvidence()
        refinesWheelbaseAutomatically = UserDefaults.standard.object(forKey: Self.refinesKey) as? Bool ?? true
        gpsCancellable = gpsTrace.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        gpsTrace.onRecord = { [weak motion] entry, sessionID in
            motion?.recordGPSReference(entry, sessionID: sessionID)
        }
        motion.onCalibration = { [weak self] progress, message in
            guard let self, self.phase == .calibrating else {
                return
            }
            self.lastSensorReport = Date()
            self.calibrationProgress = progress
            self.message = message
            if progress >= 1 {
                self.hasCompletedAppCalibration = true
                self.phase = .tracking
            }
        }
        motion.onUpdate = { [weak self] result, sample, notice, bytes in
            guard let self, self.phase == .tracking || self.phase == .calibrating else {
                return
            }
            self.lastSensorReport = Date()
            self.estimate = result
            self.sample = sample
            self.recordingBytes = bytes
            self.message = result.status
            if let notice {
                self.message = notice
                self.recordingFailure = notice
            }
            if let last = self.trail.last {
                if (result.coordinate.metres - last.metres).length > 2 {
                    self.trail.append(result.coordinate)
                }
            } else {
                self.trail.append(result.coordinate)
            }
            if self.trail.count > 1800 {
                self.trail.removeFirst(self.trail.count - 1800)
            }
            if result.needsReset {
                self.pause(reason: result.status)
            }
        }
        motion.onVibrationSpeed = { [weak self] observation in
            guard let self, self.phase == .tracking else {
                return
            }
            self.vibrationSpeed = observation
        }
        motion.onWheelbaseEvidence = { [weak self] evidence in
            self?.learnWheelbase(evidence)
        }
        motion.onFailure = { [weak self] message in
            guard let self else {
                return
            }
            self.pause(reason: message)
        }
        motion.onSpeedCorrection = { [weak self] correction, count in
            guard let self, self.phase == .tracking else {
                return
            }
            self.speedCorrectionCount = count
            let change = Int(((correction.measured - correction.before) * 3.6).rounded())
            self.speedCorrectionHint = "Speed corrected \(change > 0 ? "+" : "")\(change) km/h from road bumps"
            self.speedHintGeneration += 1
            let generation = self.speedHintGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                if self?.speedHintGeneration == generation {
                    self?.speedCorrectionHint = nil
                }
            }
        }
        motion.onFinished = { [weak self] url in
            if let url {
                self?.lastRecording = url
            }
        }
        lastRecording = DriveRecorder.recordings().first
        loadGraph()
    }

    var coordinate: Coordinate? {
        if phase != .selecting, let estimate {
            return estimate.coordinate
        }
        if let graph, let selection {
            return graph.coordinate(selection)
        }
        return nil
    }

    var heading: Double {
        if phase != .selecting, let estimate {
            return estimate.heading
        }
        if let graph, let selection {
            return graph.edges[selection.edge].heading(at: selection.distance)
        }
        return 0
    }

    var roadName: String {
        var position = selection
        if phase != .selecting, let estimate {
            position = estimate.position
        }
        guard let graph, let position else {
            return "Select your starting road"
        }
        let road = graph.edges[position.edge].record
        if road.name.isEmpty {
            return "Unnamed road"
        }
        return road.name
    }

    var canReverse: Bool {
        guard !routeLocked && !planningRoute else {
            return false
        }
        guard let graph, let selection else {
            return false
        }
        return graph.reverse(selection) != nil
    }

    func select(_ coordinate: Coordinate, maximumDistance: Double = 70) {
        guard phase == .selecting, !routeLocked, !planningRoute, let graph else {
            return
        }
        guard let position = graph.nearest(coordinate, maximumDistance: maximumDistance) else {
            message = "Tap closer to a road inside the \(region.name) coverage"
            selectionProblem = "No mapped road within \(Int(maximumDistance)) m of that place. Tap a road on the map instead."
            return
        }
        selectionProblem = nil
        if choosingDestination, let selection {
            planRoute(from: selection, to: position, graph: graph)
            return
        }
        selectedRoute = nil
        selection = position
        estimate = nil
        message = "Drag the marker along the road · check the arrow"
    }

    func drag(to coordinate: Coordinate) {
        guard phase == .selecting, !routeLocked, !choosingDestination, !planningRoute, let graph, let selection else {
            return
        }
        self.selection = graph.drag(selection, toward: coordinate)
        selectedRoute = nil
    }

    func reverseDirection() {
        guard phase == .selecting, !routeLocked, !planningRoute, let graph, let selection, let reversed = graph.reverse(selection) else {
            return
        }
        self.selection = reversed
        selectedRoute = nil
        choosingDestination = false
    }

    func chooseDestination() {
        guard phase == .selecting, selection != nil, !routeLocked, !planningRoute else {
            return
        }
        choosingDestination = true
        pendingDestinationName = nil
        selectionProblem = nil
        message = "Tap point B on the map · preview the shortest legal route"
    }

    /// Back from choosing B to adjusting the starting point.
    func cancelDestination() {
        guard phase == .selecting, choosingDestination, !planningRoute else {
            return
        }
        choosingDestination = false
        selectionProblem = nil
        message = "Drag the marker along the road · check the arrow"
    }

    func showRouteOverview() {
        follow = false
        routeOverviewRequest += 1
    }

    /// Distance left along the chosen route and the planned time for it.
    struct TripProgress {
        let remainingMetres: Double
        let remainingSeconds: Double?
        let destination: String
    }

    var tripProgress: TripProgress? {
        guard let route = selectedRoute, let graph, let index = routeIndex, index.route == route else {
            return nil
        }
        var position = selection
        if phase != .selecting, let estimate {
            position = estimate.position
        }
        let offset = position.flatMap { position in
            return index.offset(of: position)
        } ?? 0
        let remaining = max(0, index.length - offset)
        let seconds = plannedRouteSeconds.map { planned in
            return planned * remaining / max(1, index.length)
        }
        let street = graph.edges[route.destination.edge].record.name
        return TripProgress(remainingMetres: remaining, remainingSeconds: seconds,
                            destination: destinationName ?? (street.isEmpty ? "Destination" : street))
    }

    private func planRoute(from start: RoadPosition, to destination: RoadPosition, graph: RoadGraph) {
        planningRoute = true
        let generation = UUID()
        routeGeneration = generation
        message = "Finding offline driving routes"
        let phaseAtRequest = phase
        Task {
            let options = await Task.detached(priority: .userInitiated) {
                return RoutePlanner.alternatives(graph: graph, start: start, destination: destination)
            }.value
            guard generation == self.routeGeneration, self.phase == phaseAtRequest else {
                return
            }
            self.planningRoute = false
            guard let first = options.first else {
                self.message = "No legal route from this direction. Choose another point B or reset your starting point."
                self.selectionProblem = "No legal route from this start direction. Choose another destination, or go back and flip the arrow."
                return
            }
            self.routeOptions = options
            self.selectedRouteIndex = 0
            self.selectedRoute = first.route
            self.plannedRouteSeconds = first.seconds
            if let name = self.pendingDestinationName {
                self.destinationName = name
                self.pendingDestinationName = nil
            } else if phaseAtRequest == .selecting {
                self.destinationName = nil
            }
            self.choosingDestination = false
            self.routeLocked = true
            if options.count > 1 {
                self.message = "\(options.count) routes · choose one, then start"
            } else {
                self.message = "Route ready · follow the blue line during the drive"
            }
        }
    }

    /// Chooses among the offered routes before starting or resuming.
    func chooseRoute(_ index: Int) {
        guard routeOptions.indices.contains(index), !planningRoute,
              (phase == .selecting && routeLocked) || (phase == .paused && canResumeHere) else {
            return
        }
        selectedRouteIndex = index
        selectedRoute = routeOptions[index].route
        plannedRouteSeconds = routeOptions[index].seconds
        message = "\(routeOptions[index].label) route chosen"
    }

    /// While paused on the route, offers routes from the current position to
    /// the same destination. Resuming then records a segment with the new route.
    func changeRouteFromHere() {
        guard phase == .paused, canResumeHere, !planningRoute, let graph, let selection, let route = selectedRoute else {
            return
        }
        planRoute(from: selection, to: route.destination, graph: graph)
    }

    /// Search results set point A or B when the map is waiting for one;
    /// otherwise they only move the map.
    func useSearchResult(_ result: SearchResult) {
        useSearchCoordinate(result.entry.coordinate, name: result.entry.name)
    }

    func useSearchCoordinate(_ coordinate: Coordinate, name: String? = nil) {
        mapFocus = coordinate
        mapFocusRequest += 1
        if phase == .selecting, !routeLocked, !planningRoute {
            if choosingDestination {
                pendingDestinationName = name
            }
            // Place markers sit in village centres, often away from a road.
            select(coordinate, maximumDistance: 400)
        }
    }

    /// A place from Google Maps or another app, shared or pasted: it becomes
    /// point A or B like a search result, or is shown when neither is open.
    /// Returns false when it lies outside the loaded map.
    @discardableResult
    func useSharedPlace(_ place: SharedPlace) -> Bool {
        guard let graph else {
            pendingSharedPlace = place
            return true
        }
        let coordinate = Coordinate(latitude: place.latitude, longitude: place.longitude)
        guard graph.contains(coordinate) else {
            selectionProblem = "That place is outside the \(region.name) map. Choose another map in Settings first."
            return false
        }
        useSearchCoordinate(coordinate, name: place.name ?? "Shared place")
        return true
    }

    func open(_ url: URL) {
        if let place = SharedPlaceResolver.place(fromAppURL: url) {
            sharedPlaceArrivals += 1
            useSharedPlace(place)
        }
    }

    var searchPurpose: String {
        guard phase == .selecting, !routeLocked else {
            return "Choose a result to show it on the map"
        }
        if choosingDestination {
            return "Choose a result as destination B"
        }
        return selection == nil ? "Choose a result as your starting point" : "Choose a result to move your starting point"
    }

    func lockRoute() {
        guard phase == .selecting, selectedRoute != nil, !planningRoute else {
            return
        }
        routeLocked = true
        choosingDestination = false
        message = "Route locked · changing it requires resetting the starting point"
    }

    func start() {
        guard phase == .selecting || phase == .paused,
              let graph, let selection, let selectedRoute, routeLocked, mapReady, !planningRoute else {
            return
        }
        var uncertainty = 8.0
        if phase == .paused {
            guard canResumeHere else {
                setPositionAgain()
                return
            }
            uncertainty = estimate?.uncertainty ?? 8
        }
        let reuseCalibration = hasCompletedAppCalibration
        if reuseCalibration {
            phase = .tracking
        } else {
            phase = .calibrating
        }
        showingReplay = false
        recordingFailure = nil
        recordingBytes = 0
        calibrationProgress = 0
        // Offered routes started at the original point A; after starting they
        // only return through "Change route" while paused.
        routeOptions = []
        selectedRouteIndex = 0
        estimate = nil
        trail = []
        sample = nil
        vibrationSpeed = nil
        speedCorrectionCount = 0
        speedCorrectionHint = nil
        if reuseCalibration {
            message = "Calibration reused · ready to drive"
        } else {
            message = "Keep the car stopped and the phone mounted"
        }
        follow = true
        cameraRequest += 1
        lastSensorReport = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        var metadata = recordingMetadata()
        metadata["previousRecording"] = lastRecording?.lastPathComponent
        let sessionID = UUID()
        motion.start(graph: graph, position: selection, uncertainty: uncertainty, metadata: metadata, sessionID: sessionID, route: selectedRoute, reuseCalibration: reuseCalibration, wheelbase: wheelbaseMetres,
                     wheelbaseEvidence: wheelbaseEvidence.intervals > 0 ? wheelbaseEvidence : nil,
                     refinesWheelbase: refinesWheelbaseAutomatically)
        gpsTrace.beginRide(sessionID: sessionID)
        background.begin()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .tracking || self.phase == .calibrating else {
                    return
                }
                if Date().timeIntervalSince(self.lastSensorReport) > 3 {
                    self.pause(reason: "Motion data stopped · remount and set position")
                    return
                }
                self.recordDeviceContext(event: "periodic")
            }
        }
    }

    func pause(reason: String = "Paused · phone is free to use") {
        gpsTrace.endRide(reason: reason)
        background.end()
        recordDeviceContext(event: reason)
        motion.stop(reason: reason)
        watchdog?.invalidate()
        watchdog = nil
        UIApplication.shared.isIdleTimerDisabled = false
        UIDevice.current.isBatteryMonitoringEnabled = false
        if let estimate {
            selection = estimate.position
        }
        phase = .paused
        canResumeHere = false
        if let estimate, !estimate.needsReset, estimate.roadProbability > 0.8, estimate.uncertainty < 35 {
            canResumeHere = true
        }
        message = reason
        follow = false
    }

    /// Keeps the pooled evidence and, when confident, makes it the setting. The
    /// running drive already uses the learned value; the setting affects later drives.
    private func learnWheelbase(_ evidence: WheelbaseEvidence) {
        wheelbaseEvidence = evidence
        guard refinesWheelbaseAutomatically, evidence.isConfident, let estimate = evidence.estimate,
              VehicleSpeedObserver.supportedWheelbase.contains(estimate) else {
            return
        }
        let rounded = (estimate * 100).rounded() / 100
        guard abs(rounded - wheelbaseMetres) >= 0.01 else {
            return
        }
        applyingLearnedWheelbase = true
        wheelbaseMetres = rounded
        applyingLearnedWheelbase = false
    }

    /// Switches the bundled map. Only while no drive is active: the graph also
    /// sets the measuring plane, and positions and routes belong to one map.
    func selectRegion(_ newRegion: MapRegion) {
        guard newRegion != region, phase == .selecting || phase == .paused else {
            return
        }
        resetEverything()
        region = newRegion
        UserDefaults.standard.set(newRegion.id, forKey: Self.regionKey)
        graph = nil
        placeSearch = nil
        mapReady = false
        mapViewport = nil
        phase = .loading
        message = "Loading the \(newRegion.name) map"
        loadGraph()
    }

    func setPositionAgain() {
        destinationName = nil
        selectionProblem = nil
        routeGeneration = UUID()
        selectedRoute = nil
        routeOptions = []
        selectedRouteIndex = 0
        routeLocked = false
        choosingDestination = false
        planningRoute = false
        gpsTrace.endRide(reason: "Manual position reset")
        background.end()
        replayGeneration = UUID()
        replayTask?.cancel()
        motion.stop(reason: "Manual position reset")
        watchdog?.invalidate()
        UIApplication.shared.isIdleTimerDisabled = false
        UIDevice.current.isBatteryMonitoringEnabled = false
        phase = .selecting
        canResumeHere = false
        if let estimate, !showingReplay {
            selection = estimate.position
        }
        estimate = nil
        sample = nil
        trail = []
        follow = false
        message = "Tap your current road, then check your facing direction"
        showingReplay = false
    }

    func resetEverything() {
        destinationName = nil
        selectionProblem = nil
        routeGeneration = UUID()
        replayGeneration = UUID()
        replayTask?.cancel()
        selectedRoute = nil
        routeOptions = []
        selectedRouteIndex = 0
        routeLocked = false
        choosingDestination = false
        planningRoute = false
        selection = nil
        estimate = nil
        sample = nil
        trail = []
        canResumeHere = false
        follow = false
        showingReplay = false
        gpsTrace.endRide(reason: "Reset everything")
        background.end()
        motion.stop(reason: "Reset everything")
        watchdog?.invalidate()
        watchdog = nil
        UIApplication.shared.isIdleTimerDisabled = false
        UIDevice.current.isBatteryMonitoringEnabled = false
        phase = .selecting
        message = "Tap a road to set your starting point"
    }

    private func recordingMetadata() -> [String: String] {
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { bytes in
            return String(decoding: bytes.prefix { byte in
                return byte != 0
            }, as: UTF8.self)
        }
        var metadata = [
            "hardwareModel": model,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "engineVersion": TrackingEngine.version,
            "mapRegion": region.id,
            "gravityMetresPerSecondSquared": "9.80665",
            "timeZone": TimeZone.current.identifier
        ]
        if let url = Bundle.main.url(forResource: "BuildIdentity", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let identity = try? JSONDecoder().decode([String: String].self, from: data) {
            metadata.merge(identity) { _, new in
                return new
            }
            // Record the loaded region's graph digest, not every bundled one.
            if let regional = identity["mapSHA256_\(region.id)"] {
                metadata["mapSHA256"] = regional
            }
            for key in identity.keys where key.hasPrefix("mapSHA256_") {
                metadata.removeValue(forKey: key)
            }
        }
        metadata.merge(background.recordingMetadata) { _, new in
            return new
        }
        metadata.merge(gpsTrace.recordingMetadata) { _, new in
            return new
        }
        return metadata
    }

    private func recordDeviceContext(event: String) {
        gpsTrace.refreshStatus()
        motion.recordContext(metrics: ["batteryLevel": Double(UIDevice.current.batteryLevel), "thermalState": Double(ProcessInfo.processInfo.thermalState.rawValue)], details: ["event": event, "batteryState": String(UIDevice.current.batteryState.rawValue), "lowPowerMode": String(ProcessInfo.processInfo.isLowPowerModeEnabled), "phase": phase.rawValue])
    }

    func confirmStop() {
        motion.confirmStop()
        message = "Stopped confirmed · speed reset"
    }

    func prepareBackgroundTracking() {
        background.requestPermissionIfNeeded()
    }

    func recenter() {
        follow = true
        cameraRequest += 1
    }

    /// Notification Center, Control Center and app switching keep the drive
    /// running; motion continues in the background while location permission
    /// keeps the app alive. Without it the app would be suspended, so pause.
    func sceneChanged(_ scene: ScenePhase) {
        recordDeviceContext(event: "scene-\(scene)")
        if scene == .background && (phase == .tracking || phase == .calibrating) && !background.keepsRunning {
            pause(reason: "App left the screen · allow Location to keep tracking in the background")
        }
    }

    func replay(_ url: URL) {
        guard let graph, phase != .tracking, phase != .calibrating else {
            return
        }
        gpsTrace.endRide(reason: "Replay")
        routeGeneration = UUID()
        selectedRoute = nil
        routeOptions = []
        routeLocked = false
        planningRoute = false
        choosingDestination = false
        let token = UUID()
        replayTask?.cancel()
        replayGeneration = token
        phase = .replaying
        showingReplay = true
        canResumeHere = false
        replayProgress = 0
        message = "Replaying recorded motion"
        trail = []
        follow = false
        let currentMapHash = recordingMetadata()["mapSHA256"]
        let replayRegion = region
        replayTask = Task.detached(priority: .userInitiated) {
            do {
                var engine: TrackingEngine?
                var path: [Coordinate] = []
                var count = 0
                try RecordingReader.read(url) { entry, progress in
                    count += 1
                    if count.isMultiple(of: 1000) {
                        try Task.checkCancellation()
                    }
                    if let header = entry.header {
                        let recordedRegion = MapRegion.named(header.metadata?["mapRegion"])
                        guard recordedRegion.id == replayRegion.id else {
                            throw NSError(domain: "Replay", code: 5, userInfo: [NSLocalizedDescriptionKey: "This drive was recorded on the \(recordedRegion.name) map. Switch Map region to replay it."])
                        }
                        guard (2...4).contains(header.version), (header.version < 4 || header.route != nil), header.mapSnapshot == graph.dataset.generated,
                              graph.edges.indices.contains(header.initialPosition.edge), header.initialPosition.distance.isFinite,
                              header.initialPosition.distance >= 0, header.initialPosition.distance <= graph.edges[header.initialPosition.edge].length,
                              header.initialUncertainty.isFinite, header.initialUncertainty >= 0 else {
                            throw NSError(domain: "Replay", code: 1, userInfo: [NSLocalizedDescriptionKey: "This recording uses a different engine format or map snapshot."])
                        }
                        if let recordedHash = header.metadata?["mapSHA256"], let currentMapHash, recordedHash != currentMapHash {
                            throw NSError(domain: "Replay", code: 3, userInfo: [NSLocalizedDescriptionKey: "The road graph changed. Replay requires the original map data."])
                        }
                        if let route = header.route {
                            guard route.isValid(in: graph), route.offset(of: header.initialPosition, graph: graph) != nil else {
                                throw NSError(domain: "Replay", code: 4, userInfo: [NSLocalizedDescriptionKey: "Recorded route does not match the offline map or starting position."])
                            }
                        }
                        let newEngine = TrackingEngine(graph: graph, seed: header.seed, route: header.route)
                        if let weight = header.metadata?["wheelbaseEvidenceWeight"].flatMap(Double.init),
                           let metres = header.metadata?["wheelbaseEvidenceMetres"].flatMap(Double.init),
                           let intervals = header.metadata?["wheelbaseEvidenceIntervals"].flatMap(Int.init) {
                            newEngine.seedWheelbaseCalibration(WheelbaseEvidence(weight: weight, weightedMetres: metres * weight, intervals: intervals))
                        }
                        newEngine.appliesWheelbaseCalibration = header.metadata?["wheelbaseCalibrationApplied"] != "false"
                        newEngine.start(at: header.initialPosition, uncertainty: header.initialUncertainty)
                        engine = newEngine
                    }
                    if let engine, let estimate = entry.applyMotion(to: engine) {
                        if path.isEmpty || (estimate.coordinate.metres - path[path.count - 1].metres).length > 5 {
                            path.append(estimate.coordinate)
                        }
                        if path.count > 6000 {
                            path = path.enumerated().compactMap { index, coordinate in
                                if index.isMultiple(of: 2) {
                                    return coordinate
                                }
                                return nil
                            }
                        }
                    }
                    if count.isMultiple(of: 1000) {
                        DispatchQueue.main.async {
                            if self.replayGeneration == token {
                                self.replayProgress = progress
                            }
                        }
                    }
                }
                guard let final = engine?.estimate else {
                    throw NSError(domain: "Replay", code: 2, userInfo: [NSLocalizedDescriptionKey: "Recording contains no tracking session."])
                }
                DispatchQueue.main.async {
                    guard self.replayGeneration == token else {
                        return
                    }
                    self.trail = Array(path.suffix(3000))
                    self.estimate = final
                    self.selection = final.position
                    self.phase = .paused
                    self.replayProgress = 1
                    self.message = "Recorded drive replay · set your position before driving"
                    self.cameraRequest += 1
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.replayGeneration == token else {
                        return
                    }
                    self.phase = .paused
                    self.message = "Replay failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadGraph() {
        let region = region
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let url = region.graphURL else {
                    throw NSError(domain: "Map", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bundled \(region.name) road graph is missing."])
                }
                let graph = try RoadGraph(data: Data(contentsOf: url))
                // Search is optional: a region without an index still works.
                let search = region.searchURL.flatMap { url in
                    return try? PlaceSearch(data: Data(contentsOf: url))
                }
                DispatchQueue.main.async {
                    // A newer region choice supersedes this load.
                    guard self.region == region else {
                        return
                    }
                    self.graph = graph
                    self.placeSearch = search
                    self.phase = .selecting
                    self.message = "Tap your starting road · \(region.name) works completely offline"
                    if let place = self.pendingSharedPlace {
                        self.pendingSharedPlace = nil
                        self.useSharedPlace(place)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing")
                        && !ProcessInfo.processInfo.arguments.contains("--ui-testing-no-selection") {
                        self.select(region.testingStart)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.message = "Map could not load: \(error.localizedDescription)"
                }
            }
        }
    }
}
