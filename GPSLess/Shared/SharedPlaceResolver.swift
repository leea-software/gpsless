import Foundation
import MapKit

/// Turns shared text into a place. Coordinates and full links are read
/// offline; a short link (maps.app.goo.gl) is followed online to the page it
/// points to, and a link naming a place without coordinates is looked up with
/// Apple Maps. Only the shared link or name leaves the phone.
enum SharedPlaceResolver {
    enum Failure: Error, LocalizedError {
        case nothingFound
        case offline(String)

        var errorDescription: String? {
            switch self {
            case .nothingFound:
                return "No place or coordinates found in what was shared."
            case .offline(let reason):
                return "Could not open the link: \(reason)"
            }
        }
    }

    static func resolve(_ text: String) async throws -> SharedPlace {
        if let place = MapLink.place(in: text) {
            return place
        }
        guard let url = MapLink.firstURL(in: text) else {
            throw Failure.nothingFound
        }
        var request = URLRequest(url: url, timeoutInterval: 12)
        // The mobile page carries the place in its final address or markup.
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.offline(error.localizedDescription)
        }
        let final = response.url?.absoluteString ?? ""
        if let place = MapLink.place(in: final) {
            return place
        }
        let page = String(decoding: data.prefix(3_000_000), as: UTF8.self)
        let name = MapLink.placeName(in: final) ?? MapLink.placeName(in: page)
        if let place = MapLink.place(in: page) {
            return SharedPlace(latitude: place.latitude, longitude: place.longitude, name: place.name ?? name)
        }
        if let name, let place = await lookUp(name) {
            return place
        }
        throw Failure.nothingFound
    }

    private static func lookUp(_ query: String) async -> SharedPlace? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else {
            return nil
        }
        let coordinate = item.placemark.coordinate
        return SharedPlace(latitude: coordinate.latitude, longitude: coordinate.longitude, name: item.name ?? query)
    }

    /// The app link a share hands over: gpsless://place?lat=…&lon=…&name=…
    static func appURL(for place: SharedPlace) -> URL? {
        var components = URLComponents()
        components.scheme = "gpsless"
        components.host = "place"
        components.queryItems = [URLQueryItem(name: "lat", value: String(format: "%.6f", place.latitude)),
                                 URLQueryItem(name: "lon", value: String(format: "%.6f", place.longitude))]
            + (place.name.map { [URLQueryItem(name: "name", value: $0)] } ?? [])
        return components.url
    }

    static func place(fromAppURL url: URL) -> SharedPlace? {
        guard url.scheme == "gpsless", url.host == "place",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let latitude = items.first(where: { $0.name == "lat" })?.value.flatMap(Double.init),
              let longitude = items.first(where: { $0.name == "lon" })?.value.flatMap(Double.init),
              abs(latitude) <= 90, abs(longitude) <= 180 else {
            return nil
        }
        return SharedPlace(latitude: latitude, longitude: longitude, name: items.first { $0.name == "name" }?.value)
    }

    /// Google Maps at the same place or query, in its app when installed.
    static func googleMapsURLs(query: String, near centre: (latitude: Double, longitude: Double)) -> [URL] {
        let centreText = String(format: "%.5f,%.5f", centre.latitude, centre.longitude)
        var app = URLComponents(string: "comgooglemaps://")!
        var web = URLComponents(string: "https://www.google.com/maps/search/")!
        if query.isEmpty {
            app.queryItems = [URLQueryItem(name: "center", value: centreText), URLQueryItem(name: "zoom", value: "14")]
            web = URLComponents(string: "https://www.google.com/maps/@")!
            web.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "map_action", value: "map"),
                              URLQueryItem(name: "center", value: centreText), URLQueryItem(name: "zoom", value: "14")]
        } else {
            app.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "center", value: centreText),
                              URLQueryItem(name: "zoom", value: "12")]
            web.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: query)]
        }
        return [app.url, web.url].compactMap { $0 }
    }
}
