import AppKit

/// Panneau « À propos » standard de macOS : icône, nom, version et numéro de build fournis
/// par Info.plist, complétés par une description, le lien vers le code source et les licences.
@MainActor
enum AboutPanel {
    static func show() {
        // Amplo n'a pas d'icône dans le Dock : sans activation, le panneau resterait derrière.
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    private static func credits() -> NSAttributedString {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.paragraphSpacing = 6
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centered,
        ]

        let text = NSMutableAttributedString()
        func append(_ string: String, link: URL? = nil) {
            var attributes = body
            if let link {
                attributes[.link] = link
            }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }

        append(
            "Amplifie tout le son du Mac jusqu'à 300 %, avec un limiteur contre la saturation.\n"
        )
        append("Code source sur GitHub", link: URL(string: "https://github.com/ArnRso/amplo"))
        append(
            "\nLicence GNU GPL 3.0",
            link: Bundle.main.url(forResource: "LICENSE", withExtension: "txt"),
        )
        append(" · ")
        append(
            "Composants tiers",
            link: Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
        )
        append("\nMises à jour : ")
        append("Sparkle", link: URL(string: "https://sparkle-project.org"))
        return text
    }
}
