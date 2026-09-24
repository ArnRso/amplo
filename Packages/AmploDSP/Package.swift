// swift-tools-version: 6.2
import PackageDescription

/// Traitement audio temps réel d'Amplo (routage des canaux, gain, limiteur), sans dépendance
/// au reste de l'app : testable avec `swift test`.
let package = Package(
    name: "AmploDSP",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AmploDSP", targets: ["AmploDSP"])
    ],
    targets: [
        .target(name: "AmploDSP", swiftSettings: strictSettings),
        .testTarget(
            name: "AmploDSPTests",
            dependencies: ["AmploDSP"],
            swiftSettings: strictSettings,
        ),
    ],
)

/// Réglages les plus stricts : avertissements bloquants, sûreté mémoire explicite
/// et fonctionnalités à venir de Swift activées dès maintenant.
var strictSettings: [SwiftSetting] {
    [
        .treatAllWarnings(as: .error),
        .strictMemorySafety(),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
    ]
}
