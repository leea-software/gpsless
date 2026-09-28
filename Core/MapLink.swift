import Foundation

/// A place handed over from another maps app.
public struct SharedPlace: Equatable {
    public let latitude: Double
    public let longitude: Double
    public let name: String?

    public init(latitude: Double, longitude: Double, name: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
    }
}

/// Reads a place from what another maps app shares or copies: Google and
/// Apple Maps links, geo: URIs, OpenStreetMap links and plain coordinates in
/// decimal degrees or degrees, minutes and seconds. Offline only; short links
/// such as maps.app.goo.gl reveal the place only after following their
/// redirect, which the app does online.
public enum MapLink {
    private static let number = #"(-?\d{1,3}\.\d+)"#
    private static let separator = #"\s*[,;]\s*\+?\s*"#

    /// Patterns in order of precision: a dropped or named pin first, a map's
    /// centre last.
    private static let patterns: [String] = [
        // Google place pin inside the data parameter.
        #"!3d(-?\d{1,3}\.\d+)!4d(-?\d{1,3}\.\d+)"#,
        #"geo:(-?\d{1,3}(?:\.\d+)?),(-?\d{1,3}(?:\.\d+)?)"#,
        #"(?:^|[?&;/\s"'])(?:q|query|ll|sll|daddr|destination|coordinate|saddr|markers|center)=(?:loc:)?\s*"#
            + number + separator + number,
        #"/maps/(?:search|place|dir)/"# + number + separator + number,
        #"mlat="# + number + #"&(?:amp;)?mlon="# + number,
        #"#map=\d+(?:\.\d+)?/"# + number + "/" + number,
        #"@"# + number + "," + number,
    ]

    public static func place(in text: String) -> SharedPlace? {
        let decoded = decode(text)
        let name = placeName(in: decoded)
        for pattern in patterns {
            if let (latitude, longitude) = lastPair(pattern, in: decoded) {
                return SharedPlace(latitude: latitude, longitude: longitude, name: name)
            }
        }
        if let (latitude, longitude) = degreesMinutesSeconds(in: decoded) {
            return SharedPlace(latitude: latitude, longitude: longitude, name: name)
        }
        // Bare coordinates, as Google Maps shows for a dropped pin. Several
        // decimals keep phone numbers and prices from matching.
        if firstURL(in: decoded) == nil,
           let (latitude, longitude) = lastPair(#"(?<![\d.])(-?\d{1,2}\.\d{3,})\s*[,;\s]\s*(-?\d{1,3}\.\d{3,})(?![\d.])"#, in: decoded) {
            return SharedPlace(latitude: latitude, longitude: longitude, name: nil)
        }
        return nil
    }

    /// The first web link in shared text, for links that must be followed.
    public static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            return match.url
        }.first { url in
            return url.scheme == "https" || url.scheme == "http"
        }
    }

    /// A place's name from a Google Maps place link or an Apple Maps query.
    public static func placeName(in text: String) -> String? {
        let candidates = [#"/maps/place/([^/@?]+)"#, #"[?&]q=([^&]+)&(?:[^#]*&)?ll="#]
        for pattern in candidates {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else {
                continue
            }
            let name = String(text[range]).replacingOccurrences(of: "+", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, lastPair(number + separator + number, in: name) == nil {
                return name
            }
        }
        return nil
    }

    /// Links are often percent-encoded inside other links (consent pages,
    /// redirects), so decoding repeats until nothing changes.
    private static func decode(_ text: String) -> String {
        var current = text.replacingOccurrences(of: "&amp;", with: "&")
        for _ in 0..<3 {
            guard let next = current.removingPercentEncoding, next != current else {
                break
            }
            current = next
        }
        return current
    }

    private static func lastPair(_ pattern: String, in text: String) -> (Double, Double)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let first = Range(match.range(at: 1), in: text), let second = Range(match.range(at: 2), in: text),
                  let latitude = Double(text[first]), let longitude = Double(text[second]),
                  valid(latitude, longitude) else {
                continue
            }
            return (latitude, longitude)
        }
        return nil
    }

    private static func degreesMinutesSeconds(in text: String) -> (Double, Double)? {
        let part = #"(\d{1,3})\s*°\s*(\d{1,2}(?:\.\d+)?)\s*['′]\s*(?:(\d{1,2}(?:\.\d+)?)\s*(?:"|″|''))?\s*([NSEW])"#
        guard let regex = try? NSRegularExpression(pattern: part + #"[\s,]*"# + part) else {
            return nil
        }
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        func value(_ offset: Int) -> (Double, String)? {
            func group(_ index: Int) -> String? {
                return Range(match.range(at: offset + index), in: text).map { range in
                    return String(text[range])
                }
            }
            guard let degrees = group(1).flatMap(Double.init), let minutes = group(2).flatMap(Double.init),
                  let hemisphere = group(4) else {
                return nil
            }
            let seconds = group(3).flatMap(Double.init) ?? 0
            let magnitude = degrees + minutes / 60 + seconds / 3600
            return (hemisphere == "S" || hemisphere == "W" ? -magnitude : magnitude, hemisphere)
        }
        guard let first = value(0), let second = value(4) else {
            return nil
        }
        let latitudeFirst = first.1 == "N" || first.1 == "S"
        let latitude = latitudeFirst ? first.0 : second.0
        let longitude = latitudeFirst ? second.0 : first.0
        return valid(latitude, longitude) ? (latitude, longitude) : nil
    }

    private static func valid(_ latitude: Double, _ longitude: Double) -> Bool {
        return abs(latitude) <= 90 && abs(longitude) <= 180 && !(latitude == 0 && longitude == 0)
    }
}
