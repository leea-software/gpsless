import SwiftUI

/// The one screen of the app: the map, a search bar or trip banner at the top,
/// map controls on the right and a card at the bottom for the current step.
struct DrivingScreen: View {
    @ObservedObject var store: NavigationStore
    @State private var showStart = false
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showSatellite = false
    /// The satellite map stays mounted after first use so it can be aligned
    /// and rendered before it fades in.
    @State private var satelliteMounted = false
    @State private var satelliteRevealRequest = 0
    @State private var satelliteRevealPending = false
    @State private var satelliteStatus = "Loading online imagery…"
    @State private var cardHeight: CGFloat = 160

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()
            OfflineMapView(store: store, bottomInset: cardHeight + 24, isActive: !showSatellite)
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
            }
            VStack(spacing: 12) {
                topBar
                HStack(alignment: .top) {
                    toast
                    Spacer(minLength: 12)
                    mapControls
                }
                Spacer(minLength: 0)
                DriveCard(store: store, onStart: {
                    showStart = true
                }, onSearch: {
                    showSearch = true
                })
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: CardHeightKey.self, value: proxy.size.height)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .onPreferenceChange(CardHeightKey.self) { height in
            cardHeight = height
        }
        .onChange(of: store.sharedPlaceArrivals) {
            // Coming back from Google Maps usually lands on the search sheet
            // that opened it; the shared point is on the map behind it.
            showSearch = false
            showSettings = false
            showStart = false
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: store.phase)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: store.speedCorrectionHint)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .sensoryFeedback(.impact(weight: .medium), trigger: store.phase)
        .sensoryFeedback(.selection, trigger: store.selectedRouteIndex)
        .sheet(isPresented: $showStart) {
            StartDriveSheet(store: store) {
                showStart = false
                store.start()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store)
        }
        .sheet(isPresented: $showSearch) {
            PlaceSearchView(store: store, usesAppleMaps: showSatellite)
        }
    }

    private var isDriving: Bool {
        return store.phase == .tracking || store.phase == .calibrating
    }

    @ViewBuilder
    private var topBar: some View {
        if isDriving {
            if let trip = store.tripProgress {
                TripBanner(trip: trip)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        } else {
            HStack(spacing: 10) {
                Button {
                    showSearch = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.secondaryText)
                        Text(showSatellite ? "Search Apple Maps" : "Search \(store.region.name)")
                            .font(.body)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 50)
                    .background {
                        Capsule()
                            .fill(Theme.surface.opacity(0.92))
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .overlay(Capsule().strokeBorder(Theme.stroke))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                }
                .buttonStyle(.plain)
                .disabled(store.placeSearch == nil || store.phase == .replaying)
                .accessibilityLabel("Search places and streets")
                .accessibilityIdentifier("openSearch")
                MapControlButton(symbol: "gearshape.fill", label: "More") {
                    showSettings = true
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var mapControls: some View {
        VStack(spacing: 10) {
            MapControlButton(symbol: showSatellite || satelliteRevealPending ? "map.fill" : "globe.europe.africa.fill",
                             label: showSatellite ? "Show offline map" : "Show satellite map",
                             active: showSatellite || satelliteRevealPending) {
                toggleSatellite()
            }
            .accessibilityIdentifier("openSatellite")
            if store.coordinate != nil {
                MapControlButton(symbol: store.follow ? "location.fill" : "location", label: "Centre on position",
                                 active: store.follow && isDriving) {
                    store.recenter()
                }
            }
            if store.selectedRoute != nil {
                MapControlButton(symbol: "point.topleft.down.to.point.bottomright.curvepath", label: "Show whole route") {
                    store.showRouteOverview()
                }
            }
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let hint = store.speedCorrectionHint {
            Label(hint, systemImage: "waveform.path")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.background)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.accent, in: Capsule())
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("speedCorrectionHint")
        }
    }

    private func toggleSatellite() {
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
    }
}

private struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 160

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Where the drive is going and how far is left, shown while driving.
private struct TripBanner: View {
    let trip: NavigationStore.TripProgress

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "flag.checkered")
                .font(.body.weight(.bold))
                .foregroundStyle(Theme.background)
                .frame(width: 40, height: 40)
                .background(Theme.route, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.destination)
                    .font(.headline)
                    .lineLimit(1)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.surface.opacity(0.92))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.stroke))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .foregroundStyle(Theme.primaryText)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts = [Format.distance(trip.remainingMetres)]
        if let seconds = trip.remainingSeconds {
            parts.append(Format.duration(seconds))
            parts.append("arrive \(Format.arrival(after: seconds))")
        }
        return parts.joined(separator: " · ")
    }
}
