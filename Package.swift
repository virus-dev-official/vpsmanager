// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VPSManager",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "VPSManager",
            dependencies: ["SwiftTerm"],
            path: "Sources/VPSManager",
            exclude: [
                "Resources/Info.plist"
            ],
            resources: [
                .process("Resources/Assets.xcassets")
            ],
            linkerSettings: [
                .linkedFramework("CoreServices"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/VPSManager/Resources/Info.plist"
                ])
            ]
        )
    ]
)