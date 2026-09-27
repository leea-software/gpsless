import MapKit
import SwiftUI

/// Search for a place to show on the map or use as point A or B. The offline
/// index covers the loaded region's villages, towns, districts and streets.
/// Over satellite imagery, which is Apple's map, Apple Maps suggestions
/// (addresses and businesses, online) are listed first.
struct PlaceSearchView: View {
    @ObservedObject var store: NavigationStore
    let usesAppleMaps: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var searchedQuery = ""
    @State private var resolving = false
    @StateObject private var apple = AppleMapsSearch()

    private var trimmedQuery: String {
        return query.trimmingCharacters(in: .whitespaces)
    }

    private var near: Coordinate {
        return store.coordinate ?? store.mapViewport?.center ?? store.region.center
    }

    var body: some View {
        NavigationStack {
            List {
                if trimmedQuery.isEmpty {
                    Section {
                        Text(store.searchPurpose)
                        Text(usesAppleMaps
                             ? "Apple Maps finds addresses and businesses online; the offline index below still works without a connection."
                             : "Type a village, town, district or street in Ukrainian or Latin letters, for example Slavske, Тухолька or Shevchenka. Search works offline.")
                            .font(.footnote)
                            .foregroundStyle(AppColors.secondary)
                    }
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
                                    resultLabel(completion.title, detail: completion.subtitle)
                                }
                                .disabled(resolving)
                                .accessibilityIdentifier("appleSearchResult")
                            }
                        }
                    }
                    if !results.isEmpty {
                        Section(usesAppleMaps ? "Offline map" : store.searchPurpose) {
                        ForEach(results) { result in
                            Button {
                                store.useSearchResult(result)
                                dismiss()
                            } label: {
                                resultLabel(result.entry.name, detail: detail(result))
                            }
                            .accessibilityIdentifier("searchResult")
                        }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: usesAppleMaps ? "Address, place or street" : "Village, town or street")
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
            // Each keystroke cancels the previous search; the index runs off
            // the main thread after a short pause in typing.
            .task(id: trimmedQuery) {
                let text = trimmedQuery
                if usesAppleMaps {
                    apple.update(query: text, near: store.mapViewport, fallback: near)
                }
                guard !text.isEmpty, let search = store.placeSearch else {
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
    }

    private func resultLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .foregroundStyle(.primary)
            if !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondary)
            }
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
        store.useSearchCoordinate(coordinate)
        dismiss()
    }

    private func detail(_ result: SearchResult) -> String {
        let kinds = ["city": "City", "town": "Town", "village": "Village", "hamlet": "Hamlet", "suburb": "District",
                     "neighbourhood": "Neighbourhood", "quarter": "Neighbourhood", "street": "Street"]
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
