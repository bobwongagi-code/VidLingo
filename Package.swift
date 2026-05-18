// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VidLingo",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "VidLingo", targets: ["VidLingo"])
    ],
    targets: [
        .target(name: "VidLingoCore"),
        .executableTarget(
            name: "VidLingo",
            dependencies: ["VidLingoCore"],
            linkerSettings: [
                .linkedFramework("AVKit"),
                .linkedFramework("Security")
            ]
        )
    ]
)
