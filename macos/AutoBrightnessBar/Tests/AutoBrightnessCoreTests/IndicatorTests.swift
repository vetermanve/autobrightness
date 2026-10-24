import XCTest
@testable import AutoBrightnessCore

final class IndicatorTests: XCTestCase {

    func decode(_ s: String) throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: Data(s.utf8))
    }

    func testFullSnapshot() throws {
        let snap = try decode("""
        {"contract":1,"paused":false,
         "ambient":{"nits":137.5,"source":"als","age":0,"slider":0.5822,"elevation":-33.3},
         "model":{"bins":12,"bins_total":36,"bin_deg":5,"on":true},
         "manual":null,
         "displays":[{"name":"CR270ST","mode":"ddc","connected":true,"target_lum":55,
                      "target_blue":45,"lum":55,"blue":45,"age":3}]}
        """)
        XCTAssertEqual(snap.contract, requiredContract)
        XCTAssertEqual(snap.ambient.nits, 137.5)
        XCTAssertEqual(AmbientSource(snap.ambient.source), .als)
        XCTAssertTrue(AmbientSource(snap.ambient.source).isMeasured)
        XCTAssertEqual(snap.displays.first?.target_lum, 55)
        XCTAssertNil(snap.manual)
    }

    // What a cold start with the lid already shut actually prints: no reading,
    // no model, no targets. The app has to render that, not fail on it.
    func testNothingKnownYet() throws {
        let snap = try decode("""
        {"contract":1,"paused":false,
         "ambient":{"nits":null,"source":"none","age":0,"slider":null,"elevation":null},
         "model":{"bins":0,"bins_total":36,"bin_deg":5,"on":false},
         "manual":null,
         "displays":[{"name":"CR270ST","mode":"ddc","connected":true,"target_lum":null,
                      "target_blue":null,"lum":90,"blue":50,"age":40763}]}
        """)
        XCTAssertNil(snap.ambient.nits)
        XCTAssertEqual(AmbientSource(snap.ambient.source), .none)
        XCTAssertFalse(AmbientSource(snap.ambient.source).isMeasured)
        XCTAssertNil(snap.displays.first?.target_lum)
        XCTAssertEqual(snap.displays.first?.lum, 90)
    }

    func testManualAndPaused() throws {
        let snap = try decode("""
        {"contract":1,"paused":true,
         "ambient":{"nits":42,"source":"manual","age":120,"slider":null,"elevation":-10.0},
         "model":{"bins":3,"bins_total":36,"bin_deg":5,"on":true},
         "manual":{"nits":42},"displays":[]}
        """)
        XCTAssertTrue(snap.paused)
        XCTAssertEqual(snap.manual?.nits, 42)
        XCTAssertEqual(AmbientSource(snap.ambient.source), .manual)
        XCTAssertFalse(AmbientSource(snap.ambient.source).isMeasured)
    }

    func testAnOlderAgentWithoutAContractField() throws {
        let snap = try decode("""
        {"paused":false,
         "ambient":{"nits":5,"source":"hold","age":900,"slider":null,"elevation":null},
         "model":{"bins":0,"bins_total":36,"bin_deg":5,"on":false},
         "manual":null,"displays":[]}
        """)
        XCTAssertNil(snap.contract)
        XCTAssertEqual(snap.ambient.age, 900)
    }

    func testUnknownSourceNameDoesNotCrash() throws {
        let snap = try decode("""
        {"contract":1,"paused":false,
         "ambient":{"nits":5,"source":"telepathy","age":0,"slider":null,"elevation":null},
         "model":{"bins":0,"bins_total":36,"bin_deg":5,"on":false},
         "manual":null,"displays":[]}
        """)
        XCTAssertEqual(AmbientSource(snap.ambient.source), .none)
    }
}
