import MapKit
import SwiftUI

/// Search for a place to show on the map or use as point A or B. The offline
/// index covers the loaded region's villages, towns, districts and streets.
/// Over satellite imagery, which is Apple's map, Apple Maps suggestions
/// (addresses and businesses, online) are listed first. Google Maps opens
/// with the same query; a place shared from it, or its copied link or
/// coordinates, becomes point A or B.
struct PlaceSearchView: View {
    @ObservedObject var store: NavigationStore
    let usesAppleMaps: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var resolvingShared = false
    @State private var handoffStatus: String?
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var searchedQuery = ""
    @State private var resolving = false
    @State private var searchFocused = false
    @StateObject private var apple = AppleMapsSearch()

    private var trimmedQuery: String {
        return query.trimmingCharacters(in: .whitespaces)
    }

    /// A pasted or typed link or coordinates: offered as a place, not searched.
    private var queryIsLink: Bool {
        return !trimmedQuery.isEmpty && (MapLink.place(in: trimmedQuery) != nil || MapLink.firstURL(in: trimmedQuery) != nil)
    }

    private var near: Coordinate {
        return store.coordinate ?? store.mapViewport?.center ?? store.region.center
    }

    var body: some View {
        NavigationStack {
            List {
                if queryIsLink {
                    Section("Link or coordinates") {
                        Button {
                            Task {
                                await resolveShared(trimmedQuery)
                            }
                        } label: {
                            resultLabel(linkTitle, detail: "Use as \(pointName)", symbol: "link.circle.fill")
                        }
                        .disabled(resolvingShared)
                        .accessibilityIdentifier("useTypedLink")
                    }
                    .listRowBackground(Theme.surface)
                }
                if trimmedQuery.isEmpty {
                    Section {
                        Text(store.searchPurpose)
                        Text(usesAppleMaps
                             ? "Apple Maps finds addresses and businesses online; the offline index below still works without a connection."
                             : "Type a village, town, district or street in Ukrainian or Latin letters, for example Slavske, Тухолька or Shevchenka. Search works offline.")
                            .font(.footnote)
                            .foregroundStyle(AppColors.secondary)
                    }
                    .listRowBackground(Theme.surface)
                } else if queryIsLink {
                    EmptyView()
                } else if searchedQuery == trimmedQuery && results.isEmpty && (!usesAppleMaps || apple.completions.isEmpty) {
                    Section {
                        if let status = apple.status, usesAppleMaps {
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(AppColors.secondary)
                        }
                        ContentUnavailableView.search(text: trimmedQuery)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    if usesAppleMaps && (!apple.completions.isEmpty || apple.status != nil) {
                        Section("Apple Maps") {
                            if let status = apple.status {
                                Text(status)
                                    .font(.footnote)
                                    .foregroundStyle(AppColors.secondary)
                            }
                            ForEach(Array(apple.completions.prefix(12).enumerated()), id: \.offset) { _, completion in
                                Button {
                                    Task {
                                        await useAppleResult(completion)
                                    }
                                } label: {
                                    resultLabel(completion.title, detail: completion.subtitle, symbol: "mappin.circle.fill")
                                }
                                .disabled(resolving)
                                .accessibilityIdentifier("appleSearchResult")
                            }
                        }
                        .listRowBackground(Theme.surface)
                    }
                    if !results.isEmpty {
                        Section(usesAppleMaps ? "Offline map" : store.searchPurpose) {
                        ForEach(results) { result in
                            Button {
                                store.useSearchResult(result)
                                dismiss()
                            } label: {
                                resultLabel(result.entry.name, detail: detail(result), symbol: symbol(for: result.entry.kind))
                            }
                            .accessibilityIdentifier("searchResult")
                        }
                        }
                        .listRowBackground(Theme.surface)
                    }
                }
                handoff
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $query, isPresented: $searchFocused, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: usesAppleMaps ? "Address, place or street" : "Village, town, street or fuel")
            .autocorrectionDisabled()
            .navigationTitle(usesAppleMaps ? "Search Apple Maps" : "Search \(store.region.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Ready to type, as in Maps.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    searchFocused = true
                }
            }
            // Each keystroke cancels the previous search; the index runs off
            // the main thread after a short pause in typing.
            .task(id: trimmedQuery) {
                let text = trimmedQuery
                // A link is resolved on its own, never sent to Apple as a query.
                let isLink = queryIsLink
                if usesAppleMaps {
                    apple.update(query: isLink ? "" : text, near: store.mapViewport, fallback: near)
                }
                guard !text.isEmpty, !isLink, let search = store.placeSearch else {
                    results = []
                    searchedQuery = text
                    return
                }
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else {
                    return
                }
                let origin = near
                let found = await Task.detached(priority: .userInitiated) {
                    return search.search(text, near: origin)
                }.value
                guard !Task.isCancelled else {
                    return
                }
                results = found
                searchedQuery = text
            }
        }
        .presentationBackground(Theme.background)
        .preferredColorScheme(.dark)
    }

    /// Google Maps finds more than either index. Its place comes back by
    /// Share → GPSLess, or by copying the link and pasting it here.
    private var handoff: some View {
        Section {
            Button {
                openGoogleMaps()
            } label: {
                resultLabel(trimmedQuery.isEmpty || queryIsLink ? "Find it in Google Maps" : "Search “\(trimmedQuery)” in Google Maps",
                            detail: "Then tap Share → GPSLess on the place, or copy its link or coordinates and paste them here.",
                            symbol: "arrow.up.forward.app.fill")
            }
            .accessibilityIdentifier("openGoogleMaps")
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Copied a place?")
                        .foregroundStyle(Theme.primaryText)
                    Text("A Google or Apple Maps link, or coordinates")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 8)
                PasteButton(supportedContentTypes: [.url, .plainText]) { providers in
                    paste(providers)
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .tint(Theme.accent)
                .disabled(resolvingShared)
                .accessibilityIdentifier("pastePlace")
            }
            if resolvingShared {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Opening the link…")
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            if let handoffStatus {
                Label(handoffStatus, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }
        } header: {
            Text("Google Maps")
        }
        .listRowBackground(Theme.surface)
    }

    private var pointName: String {
        if store.phase != .selecting || store.routeLocked {
            return "a map position"
        }
        if store.choosingDestination {
            return "destination B"
        }
        return "starting point A"
    }

    private var linkTitle: String {
        if let place = MapLink.place(in: trimmedQuery) {
            return place.name ?? String(format: "%.5f, %.5f", place.latitude, place.longitude)
        }
        return "Open the shared link"
    }

    private func openGoogleMaps() {
        let centre = near
        let urls = SharedPlaceResolver.googleMapsURLs(query: queryIsLink ? "" : trimmedQuery, near: (centre.latitude, centre.longitude))
        guard let app = urls.first else {
            return
        }
        openURL(app) { accepted in
            if !accepted, urls.count > 1 {
                openURL(urls[1])
            }
        }
    }

    private func paste(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else {
            return
        }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    Task { @MainActor in
                        await resolveShared(url.absoluteString)
                    }
                }
            }
        } else if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                if let text {
                    Task { @MainActor in
                        await resolveShared(text)
                    }
                }
            }
        }
    }

    @MainActor
    private func resolveShared(_ text: String) async {
        resolvingShared = true
        handoffStatus = nil
        defer {
            resolvingShared = false
        }
        do {
            let place = try await SharedPlaceResolver.resolve(text)
            if store.useSharedPlace(place) {
                dismiss()
            } else {
                handoffStatus = store.selectionProblem
            }
        } catch {
            handoffStatus = error.localizedDescription
        }
    }

    private func resultLabel(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(Theme.primaryText)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case "city", "town":
            return "building.2.crop.circle.fill"
        case "village", "hamlet":
            return "house.circle.fill"
        case "street":
            return "signpost.right.circle.fill"
        case "fuel":
            return "fuelpump.circle.fill"
        default:
            return "mappin.circle.fill"
        }
    }

    private func useAppleResult(_ completion: MKLocalSearchCompletion) async {
        resolving = true
        defer {
            resolving = false
        }
        guard let coordinate = await apple.resolve(completion) else {
            return
        }
        store.useSearchCoordinate(coordinate, name: completion.title)
        dismiss()
    }

    private func detail(_ result: SearchResult) -> String {
        let kinds = ["city": "City", "town": "Town", "village": "Village", "hamlet": "Hamlet", "suburb": "District",
                     "neighbourhood": "Neighbourhood", "quarter": "Neighbourhood", "street": "Street", "fuel": "Fuel station"]
        var parts = [kinds[result.entry.kind] ?? result.entry.kind.capitalized]
        if !result.entry.context.isEmpty && result.entry.context != result.entry.name {
            parts.append(result.entry.context)
        }
        if let distance = result.distanceMetres {
            parts.append(distance < 1000 ? String(format: "%.0f m", distance) : String(format: "%.1f km", distance / 1000))
        }
        return parts.joined(separator: " · ")
    }
}

/// Apple Maps suggestions near the visible satellite map. Online only; the
/// query text is sent to Apple, never a position estimate.
@MainActor
final class AppleMapsSearch: NSObject, ObservableObject, @preconcurrency MKLocalSearchCompleterDelegate {
    @Published private(set) var completions: [MKLocalSearchCompletion] = []
    @Published private(set) var status: String?
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String, near viewport: NavigationMapViewport?, fallback: Coordinate) {
        if let viewport {
            completer.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: viewport.center.latitude, longitude: viewport.center.longitude),
                span: MKCoordinateSpan(latitudeDelta: max(viewport.latitudeDelta, 0.05), longitudeDelta: max(viewport.longitudeDelta, 0.05)))
        } else {
            completer.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: fallback.latitude, longitude: fallback.longitude),
                                                  latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        }
        if query.isEmpty {
            completer.cancel()
            completions = []
            status = nil
        } else {
            completer.queryFragment = query
        }
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> Coordinate? {
        do {
            let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
            guard let item = response.mapItems.first else {
                status = "Apple Maps returned no location for this result"
                return nil
            }
            let coordinate = item.placemark.coordinate
            return Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
        } catch {
            status = "Apple Maps unavailable · \(error.localizedDescription)"
            return nil
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        completions = completer.results
        status = nil
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        completions = []
        status = "Apple Maps unavailable offline · offline results below"
    }
}
