import XCTest
@testable import AutoBrightnessCore

final class ConfigRewriteTests: XCTestCase {

    func testAppendsWhenTheKeyIsAbsent() {
        let out = ConfigRewrite.set("MATCH=nits\n", key: "SOLAR_LAT", value: "55.7558")
        XCTAssertEqual(out, "MATCH=nits\nSOLAR_LAT=55.7558\n")
    }

    func testReplacesTheExistingAssignment() {
        let out = ConfigRewrite.set("SOLAR_LAT=10\nMATCH=nits\n", key: "SOLAR_LAT", value: "55.7")
        XCTAssertEqual(out, "SOLAR_LAT=55.7\nMATCH=nits\n")
    }

    func testKeepsTheTrailingComment() {
        let out = ConfigRewrite.set("SOLAR_LAT=10   # degrees north\n", key: "SOLAR_LAT", value: "55.7")
        XCTAssertEqual(out, "SOLAR_LAT=55.7   # degrees north\n")
    }

    // A commented-out assignment is documentation. Reviving it would change a
    // file the user reads, and silently turn an example into a setting.
    func testDoesNotReviveACommentedAssignment() {
        let out = ConfigRewrite.set("# SOLAR_LAT=10\n", key: "SOLAR_LAT", value: "55.7")
        XCTAssertEqual(out, "# SOLAR_LAT=10\nSOLAR_LAT=55.7\n")
    }

    func testDoesNotMatchALongerName() {
        let out = ConfigRewrite.set("SOLAR_LATITUDE=10\n", key: "SOLAR_LAT", value: "55.7")
        XCTAssertEqual(out, "SOLAR_LATITUDE=10\nSOLAR_LAT=55.7\n")
    }

    func testLeavesEverythingElseAlone() {
        let before = """
        # local settings, not in the repository
        DISPLAYS=(
          "CR270ST:0:90:38:50"
        )
        MATCH=nits
        SOLAR_LON=37.6
        """
        let out = ConfigRewrite.set(before, key: "SOLAR_LON", value: "37.6176")
        XCTAssertEqual(out, before.replacingOccurrences(of: "SOLAR_LON=37.6", with: "SOLAR_LON=37.6176"))
    }

    func testEmptyFile() {
        XCTAssertEqual(ConfigRewrite.set("", key: "SOLAR_LAT", value: "1"), "SOLAR_LAT=1\n")
    }

    func testFileWithoutATrailingNewline() {
        XCTAssertEqual(ConfigRewrite.set("MATCH=nits", key: "SOLAR_LAT", value: "1"),
                       "MATCH=nits\nSOLAR_LAT=1\n")
    }

    func testOnlyTheFirstAssignmentIsRewritten() {
        // A second assignment of the same key is what the shell itself honours
        // last, so leaving it is wrong - but rewriting both hides from the user
        // that their file says the same thing twice. Flagging that is the
        // settings window's job; this does the narrow edit it promises.
        let out = ConfigRewrite.set("SOLAR_LAT=1\nSOLAR_LAT=2\n", key: "SOLAR_LAT", value: "3")
        XCTAssertEqual(out, "SOLAR_LAT=3\nSOLAR_LAT=2\n")
    }
}
