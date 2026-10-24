import XCTest
@testable import AutoBrightnessCore

final class TimeZoneCoordsTests: XCTestCase {

    // a few real rows, in the two formats zone.tab actually uses
    let tab = """
    # tz	coordinates	TZ	comments
    RU\t+554521+0373704\tEurope/Moscow\tMSK+00 - Moscow area
    ZA\t-2615+02800\tAfrica/Johannesburg
    US\t+340308-1181434\tAmerica/Los_Angeles\tPacific
    AQ\t-6617+11031\tAntarctica/Casey\tCasey
    """

    func testMoscowToTheSecond() throws {
        let p = try XCTUnwrap(TimeZoneCoords.lookup(zone: "Europe/Moscow", in: tab))
        XCTAssertEqual(p.latitude, 55.7558, accuracy: 0.0002)
        XCTAssertEqual(p.longitude, 37.6178, accuracy: 0.0002)
        XCTAssertEqual(p.comment, "MSK+00 - Moscow area")
    }

    func testSouthernAndWesternAreNegative() throws {
        let jo = try XCTUnwrap(TimeZoneCoords.lookup(zone: "Africa/Johannesburg", in: tab))
        XCTAssertEqual(jo.latitude, -26.25, accuracy: 0.0002)
        XCTAssertEqual(jo.longitude, 28.0, accuracy: 0.0002)
        XCTAssertEqual(jo.comment, "")

        let la = try XCTUnwrap(TimeZoneCoords.lookup(zone: "America/Los_Angeles", in: tab))
        XCTAssertEqual(la.latitude, 34.0522, accuracy: 0.0002)
        XCTAssertEqual(la.longitude, -118.2428, accuracy: 0.0002)
    }

    func testBothFieldWidths() {
        XCTAssertEqual(TimeZoneCoords.parseISO6709("+5545+03737")?.lat ?? 0, 55.75, accuracy: 1e-9)
        XCTAssertEqual(TimeZoneCoords.parseISO6709("+554521+0373704")?.lat ?? 0, 55.7558, accuracy: 1e-4)
    }

    func testRubbishIsRefused() {
        XCTAssertNil(TimeZoneCoords.parseISO6709(""))
        XCTAssertNil(TimeZoneCoords.parseISO6709("55.75,37.61"))
        XCTAssertNil(TimeZoneCoords.parseISO6709("+5545"))            // longitude missing
        XCTAssertNil(TimeZoneCoords.parseISO6709("+5575+03737"))      // 75 minutes
        XCTAssertNil(TimeZoneCoords.parseISO6709("+55451+037370"))    // neither width
        XCTAssertNil(TimeZoneCoords.parseISO6709("+9900+03737"))      // past the pole
        XCTAssertNil(TimeZoneCoords.lookup(zone: "Mars/Olympus", in: tab))
    }

    func testCommentedRowsAreNotData() {
        XCTAssertNil(TimeZoneCoords.lookup(zone: "tz", in: tab))
    }

    // the file this reads is shipped by macOS; if it ever moves, the button that
    // depends on it should fail loudly in a test rather than quietly in the UI
    func testTheSystemTableIsWhereWeThink() throws {
        let p = try XCTUnwrap(TimeZoneCoords.current(zone: "Europe/Moscow"))
        XCTAssertEqual(p.latitude, 55.7558, accuracy: 0.01)
    }
}
