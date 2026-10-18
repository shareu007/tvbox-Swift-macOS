// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MobileNodeRuntime",
    platforms: [.iOS(.v17)],
    products: [.library(name: "TVBoxNodeRuntime", targets: ["TVBoxNodeRuntime"])],
    targets: [
        .binaryTarget(
            name: "NodeMobile",
            url: "https://github.com/fogtape/nodejs-mobile/releases/download/v24.21.0-0/nodejs-mobile-ios-24.21.0-0.zip",
            checksum: "11ce3f366dc5f5f2f58a35186b257edc4fa365f2aeb1c0fe963c35728495b492"
        ),
        .target(name: "TVBoxNodeRuntime", dependencies: ["NodeMobile"],
                exclude: ["NodeAPI/README.md"], publicHeadersPath: "include")
    ]
)
