// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AntiphonDesign",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "AntiphonDesign", targets: ["AntiphonDesign"])
    ],
    targets: [
        .target(
            name: "AntiphonDesign",
            resources: [.process("Resources")]
        )
    ]
)
