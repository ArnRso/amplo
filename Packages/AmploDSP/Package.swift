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

/// Réglages les plus stricts : sûreté mémoire explicite et fonctionnalités à venir de Swift
/// activées dès maintenant.
///
/// Les avertissements sont rendus bloquants par `scripts/test.sh` plutôt qu'ici : Xcode 26
/// compile les packages locaux en masquant leurs avertissements, ce qui entre en conflit.
var strictSettings: [SwiftSetting] {
    [
        .strictMemorySafety(),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
    ]
}
