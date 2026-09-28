import XCTest
@testable import GPSLessCore

/// Places shared or copied from other maps apps. Coordinates are public
/// landmarks (Maidan Nezalezhnosti, Kyiv).
final class MapLinkTests: XCTestCase {
    private func assertPlace(_ text: String, _ latitude: Double, _ longitude: Double, name: String? = nil,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let place = MapLink.place(in: text) else {
            return XCTFail("No place in \(text)", file: file, line: line)
        }
        XCTAssertEqual(place.latitude, latitude, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(place.longitude, longitude, accuracy: 1e-4, file: file, line: line)
        if let name {
            XCTAssertEqual(place.name, name, file: file, line: line)
        }
    }

    func testGooglePlacePinWinsOverMapCentre() {
        assertPlace("https://www.google.com/maps/place/Maidan+Nezalezhnosti/@50.4480,30.5200,17z/data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d50.4501!4d30.5234!16s",
                    50.4501, 30.5234, name: "Maidan Nezalezhnosti")
    }

    func testGoogleQueryAndSearchLinks() {
        assertPlace("https://maps.google.com/?q=50.4501,30.5234", 50.4501, 30.5234)
        assertPlace("https://www.google.com/maps/search/50.4501,+30.5234?entry=tts", 50.4501, 30.5234)
        assertPlace("https://www.google.com/maps/@50.4501,30.5234,15z", 50.4501, 30.5234)
    }

    func testLinkInsideConsentRedirect() {
        assertPlace("https://consent.google.com/ml?continue=https%3A%2F%2Fwww.google.com%2Fmaps%2Fplace%2FX%2F%4050.1%2C30.1%2C17z%2Fdata%3D%214m6%218m2%213d50.4501%214d30.5234&gl=UA",
                    50.4501, 30.5234)
    }

    func testAppleOpenStreetMapAndGeoLinks() {
        assertPlace("https://maps.apple.com/?q=Maidan&ll=50.4501,30.5234", 50.4501, 30.5234, name: "Maidan")
        assertPlace("https://www.openstreetmap.org/?mlat=50.4501&mlon=30.5234#map=17/50.4400/30.5100", 50.4501, 30.5234)
        assertPlace("https://www.openstreetmap.org/#map=17/50.4501/30.5234", 50.4501, 30.5234)
        assertPlace("geo:50.4501,30.5234?z=17", 50.4501, 30.5234)
    }

    func testPlainAndDegreeCoordinates() {
        assertPlace("50.4501, 30.5234", 50.4501, 30.5234)
        assertPlace("Pin: 50.450100 30.523400", 50.4501, 30.5234)
        assertPlace("50°27'00.4\"N 30°31'24.2\"E", 50.45011, 30.52339)
    }

    func testShortLinksAndOrdinaryTextHaveNoPlace() {
        let short = "Maidan https://maps.app.goo.gl/AbCdEf123"
        XCTAssertNil(MapLink.place(in: short))
        XCTAssertEqual(MapLink.firstURL(in: short)?.host, "maps.app.goo.gl")
        XCTAssertNil(MapLink.place(in: "Open 24/7, call 067 123 4567, 2 km"))
    }
}
