// swift-tools-version: 6.0
import PackageDescription

// Pure text and alignment logic shared by the macOS app's speech follower and
// display. Kept out of the app target so it can be unit-tested without a
// microphone: `swift test` from this directory.
let package = Package(
    name: "PrompterCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PrompterCore", targets: ["PrompterCore"]),
    ],
    targets: [
        .target(name: "PrompterCore"),
        .testTarget(
            name: "PrompterCoreTests",
            dependencies: ["PrompterCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
