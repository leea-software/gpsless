import SwiftUI

/// The bottom card: one layout per step of planning and driving.
struct DriveCard: View {
    @ObservedObject var store: NavigationStore
    var onStart: () -> Void
    var onSearch: () -> Void

    var body: some View {
        Group {
            switch store.phase {
            case .loading:
                SheetCard {
                    HStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.regular)
                        CardHeader(title: "Loading \(store.region.name)", subtitle: "Preparing the offline map")
                    }
                }
            case .selecting:
                planning
            case .calibrating:
                CalibratingCard(progress: store.calibrationProgress) {
                    store.pause()
                }
            case .tracking:
                TrackingCard(store: store)
            case .paused:
                PausedCard(store: store, onResume: onStart)
            case .replaying:
                SheetCard {
                    CardHeader(eyebrow: "Replay", title: "Recalculating the drive",
                               subtitle: "Using the installed engine on the recorded sensors")
                    ProgressView(value: store.replayProgress)
                        .tint(Theme.accent)
                    Button("Cancel replay") {
                        store.setPositionAgain()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder
    private var planning: some View {
        if store.selection == nil {
            SheetCard {
                CardHeader(eyebrow: "Step 1 of 3", title: "Where does the drive start?",
                           subtitle: "Park on a mapped road, then tap it on the map or search for it above.")
                ProblemLine(text: store.selectionProblem)
                RegionMenu(store: store)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("startingPointRequest")
        } else if store.planningRoute {
            SheetCard {
                HStack(spacing: 14) {
                    ProgressView()
                    CardHeader(title: "Finding routes", subtitle: "Planning offline on \(store.region.name)")
                }
            }
        } else if store.routeLocked, store.selectedRoute != nil {
            RoutesCard(store: store, onStart: onStart)
        } else if store.choosingDestination {
            SheetCard {
                CardHeader(eyebrow: "Step 2 of 3", title: "Where to?",
                           subtitle: "Tap the destination on the map or search for it.")
                ProblemLine(text: store.selectionProblem)
                HStack(spacing: 10) {
                    Button {
                        store.cancelDestination()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button {
                        onSearch()
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("destinationPointRequest")
        } else {
            StartPointCard(store: store)
        }
    }
}

/// Why the last point could not be used, on the planning cards.
private struct ProblemLine: View {
    let text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("selectionProblem")
        }
    }
}

/// Map region choice, in the first step and in Settings.
struct RegionMenu: View {
    @ObservedObject var store: NavigationStore

    var body: some View {
        Menu {
            Picker("Map", selection: Binding(get: {
                return store.region.id
            }, set: { id in
                store.selectRegion(MapRegion.named(id))
            })) {
                ForEach(MapRegion.all) { region in
                    Text(region.name).tag(region.id)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "map.fill")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Map")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                    Text(store.region.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        }
        .disabled(store.phase != .selecting && store.phase != .paused)
        .accessibilityIdentifier("mapRegion")
    }
}

private struct StartPointCard: View {
    @ObservedObject var store: NavigationStore

    var body: some View {
        SheetCard {
            CardHeader(eyebrow: "Step 1 of 3 · Starting point", title: store.roadName,
                       subtitle: "Drag the marker to where the car is. The arrow must point the way the car faces.")
            ProblemLine(text: store.selectionProblem)
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "location.north.fill")
                        .font(.body.weight(.bold))
                        .rotationEffect(.radians(store.heading))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 36, height: 36)
                        .background(Theme.accent.opacity(0.15), in: Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Facing")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                        Text(compassDirection)
                            .font(.headline)
                    }
                }
                Spacer()
                Button {
                    store.reverseDirection()
                } label: {
                    Label("Flip", systemImage: "arrow.up.arrow.down")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(SecondaryButtonStyle())
                .fixedSize()
                .disabled(!store.canReverse)
                .accessibilityIdentifier("flipDirection")
            }
            Button {
                store.chooseDestination()
            } label: {
                Text("Set as start")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("confirmStartingPoint")
        }
    }

    private var compassDirection: String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((store.heading + 2 * .pi + .pi / 8) / (.pi / 4)) % 8
        return directions[max(0, index)]
    }
}

/// Offered routes and the start button.
private struct RoutesCard: View {
    @ObservedObject var store: NavigationStore
    var onStart: () -> Void

    var body: some View {
        SheetCard {
            CardHeader(eyebrow: "Step 3 of 3", title: "Choose a route",
                       subtitle: store.tripProgress.map { trip in
                           return "To \(trip.destination)"
                       })
            RouteOptionList(store: store)
            Button {
                onStart()
            } label: {
                Label("Start drive", systemImage: "arrow.up.right")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!store.mapReady)
            .accessibilityIdentifier("startTracking")
            HStack {
                Button("Start over") {
                    store.resetEverything()
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("resetEverything")
                Spacer()
                Text("Times assume free-flowing traffic")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
    }
}

struct RouteOptionList: View {
    @ObservedObject var store: NavigationStore

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(store.routeOptions.enumerated()), id: \.offset) { index, option in
                let selected = index == store.selectedRouteIndex
                Button {
                    store.chooseRoute(index)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selected ? Theme.route : Theme.tertiaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Format.duration(option.seconds))
                                .font(.headline)
                                .monospacedDigit()
                            Text("\(option.label) · \(Format.distance(option.metres))")
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(selected ? Theme.route.opacity(0.14) : Theme.raised.opacity(0.6),
                                in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                            .strokeBorder(selected ? Theme.route.opacity(0.6) : .clear, lineWidth: 1.5)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("routeOption\(index)")
            }
        }
    }
}

private struct CalibratingCard: View {
    let progress: Double
    var onCancel: () -> Void

    var body: some View {
        SheetCard {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Theme.raised, lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: max(0.02, progress))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: progress)
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 56, height: 56)
                CardHeader(title: "Hold still",
                           subtitle: "Measuring the mount and sensors. Keep the car stopped and don't touch the phone.")
            }
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }
}

private struct TrackingCard: View {
    @ObservedObject var store: NavigationStore

    var body: some View {
        SheetCard {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Int((store.estimate?.speed ?? 0) * 3.6))")
                        .font(.system(size: 56, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("km/h")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    let typicalError = store.estimate?.typicalError ?? 0
                    StatusPill(text: "±\(Format.distance(typicalError))", color: Theme.uncertainty(typicalError), symbol: "scope")
                        .accessibilityLabel("Typical position error \(Format.distance(typicalError))")
                    Text(store.estimate?.status ?? "Tracking")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "road.lanes")
                    .foregroundStyle(Theme.tertiaryText)
                Text(store.roadName)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                Button {
                    store.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(PrimaryButtonStyle(tint: Theme.primaryText))
                .accessibilityIdentifier("pauseTracking")
                Button {
                    store.confirmStop()
                } label: {
                    Label("Stopped", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityHint("Tell the app the car is stationary and reset the speed")
            }
            HStack(spacing: 14) {
                Label("\(store.estimate?.anchorCount ?? 0) turn fixes", systemImage: "arrow.turn.up.right")
                Label("\(store.speedCorrectionCount) speed fixes", systemImage: "waveform.path")
                    .accessibilityIdentifier("speedCorrectionCount")
            }
            .font(.caption)
            .foregroundStyle(Theme.tertiaryText)
        }
    }
}

private struct PausedCard: View {
    @ObservedObject var store: NavigationStore
    var onResume: () -> Void

    var body: some View {
        SheetCard {
            CardHeader(eyebrow: "Paused", title: store.canResumeHere ? "Tracking paused" : "Set your position",
                       subtitle: store.message)
                .accessibilityIdentifier("trackingMessage")
            if store.canResumeHere && store.routeOptions.count > 1 {
                RouteOptionList(store: store)
            }
            if store.canResumeHere {
                Button {
                    onResume()
                } label: {
                    Label("Car stayed here · resume", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("Set position again") {
                    store.setPositionAgain()
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("setPosition")
                if store.selectedRoute != nil && store.routeOptions.isEmpty {
                    Button(store.planningRoute ? "Finding routes…" : "Change route from here") {
                        store.changeRouteFromHere()
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(store.planningRoute)
                    .accessibilityIdentifier("changeRoute")
                }
            } else {
                Button {
                    store.setPositionAgain()
                } label: {
                    Label("Set current position", systemImage: "mappin.and.ellipse")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("setPosition")
            }
        }
    }
}
