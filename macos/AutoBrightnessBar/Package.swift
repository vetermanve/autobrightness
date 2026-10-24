// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AutoBrightnessBar",
    // macOS 13: Form(.grouped) and LabeledContent give a settings grid that
    // matches System Settings without hand-laying it out
    platforms: [.macOS(.v13)],
    targets: [
        // The parts that must not be wrong: the shape of the agent's contract,
        // the nits scale the slider speaks in, and the rewrite of a config file
        // the user also edits by hand. No AppKit, so they stay testable.
        .target(name: "AutoBrightnessCore"),
        .executableTarget(name: "AutoBrightnessBar", dependencies: ["AutoBrightnessCore"]),
        .testTarget(name: "AutoBrightnessCoreTests", dependencies: ["AutoBrightnessCore"]),
    ]
)
