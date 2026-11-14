// swift-tools-version:5.9
// LJL Link (formerly "LJ Link Sender"): runs from the club's USB stick on the DJ's Mac and sends Serato deck data to LJ Link in the booth.
import PackageDescription

let package = Package(
    name: "LJLLink",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything testable: Serato log, waveforms, club config, protocol messages.
        .target(name: "SenderCore", path: "Sources/SenderCore"),
        // Command line front end for development (watch Serato, compute waveforms, previews).
        .executableTarget(name: "ljlink-sender", dependencies: ["SenderCore"], path: "Sources/ljlink-sender"),
        // The app on the club's stick: question about track names, status, decks, menu bar (build-app.sh bundles it).
        .executableTarget(name: "LJLLinkApp", dependencies: ["SenderCore"], path: "Sources/LJLLinkApp"),
        // Self test without XCTest (the Command Line Tools have no XCTest): `swift run selftest`.
        .executableTarget(name: "selftest", dependencies: ["SenderCore"], path: "Sources/selftest"),
    ]
)
