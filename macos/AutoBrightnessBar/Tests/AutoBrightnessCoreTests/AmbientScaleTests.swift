import XCTest
@testable import AutoBrightnessCore

final class AmbientScaleTests: XCTestCase {
    let s = AmbientScale()

    func testEndsLandOnTheEnds() {
        XCTAssertEqual(s.position(1.0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(s.position(400.0), 1.0, accuracy: 1e-9)
    }

    func testRoundTrip() {
        for nits in [1.0, 2.5, 20.0, 137.5, 399.0] {
            XCTAssertEqual(s.nits(s.position(nits)), nits, accuracy: 1e-6)
        }
    }

    func testOutOfRangeClamps() {
        XCTAssertEqual(s.position(0.01), 0.0, accuracy: 1e-9)
        XCTAssertEqual(s.position(5000), 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.nits(-1), 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.nits(2), 400.0, accuracy: 1e-9)
    }

    // The point of the log scale: the dim half of the slider has to cover the
    // dim half of the room, not the first few percent of travel.
    func testHalfTravelIsTheGeometricMiddle() {
        XCTAssertEqual(s.nits(0.5), 20.0, accuracy: 0.001)
    }

    func testMonotonic() {
        var last = -1.0
        for i in 0...100 {
            let v = s.nits(Double(i) / 100)
            XCTAssertGreaterThan(v, last)
            last = v
        }
    }

    func testFormatKeepsADecimalWhereItMatters() {
        XCTAssertEqual(s.format(1.4), "1.4 nits")
        // 9.95 is 9.94999... as a double, so stay off that edge here
        XCTAssertEqual(s.format(9.4), "9.4 nits")
        XCTAssertEqual(s.format(9.99), "10.0 nits")
        XCTAssertEqual(s.format(137.5), "138 nits")
    }
}
