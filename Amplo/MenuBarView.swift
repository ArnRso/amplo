import AppKit
import ServiceManagement
import SwiftUI

/// Panneau ouvert depuis l'icône de la barre des menus.
struct MenuBarView: View {
    @Bindable var controller: AmploController
    let updates: UpdateManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Amplo")
                    .font(.headline)
                Spacer()
                Toggle("Activer Amplo", isOn: $controller.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if case .failed(let message) = controller.status {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Volume : \(controller.gainPercent) %")
                    .font(.subheadline)
                Picker("Volume", selection: $controller.gainPercent) {
                    ForEach(AmploController.gainSteps, id: \.self) { percent in
                        Text("\(percent)").tag(percent)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if controller.status == .running {
                VStack(alignment: .leading, spacing: 4) {
                    Label(controller.outputName ?? "Sortie inconnue", systemImage: "hifispeaker")
                    Text(controller.limiterReductionDB < -0.1
                        ? String(format: "Limiteur : %.1f dB", controller.limiterReductionDB)
                        : "Limiteur : inactif")
                        .monospacedDigit()
                        .foregroundStyle(controller.limiterReductionDB < -0.1 ? .orange : .secondary)
                }
                .font(.caption)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Ouvrir Amplo à la connexion", isOn: $controller.launchesAtLogin)
                    .toggleStyle(.checkbox)
                if controller.loginItemStatus == .requiresApproval {
                    HStack {
                        Text("À autoriser dans Réglages Système")
                            .foregroundStyle(.orange)
                        Button("Ouvrir") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .buttonStyle(.link)
                    }
                    .font(.caption)
                }
                if let error = controller.loginItemError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            if let version = updates.availableVersion {
                Button("Installer la mise à jour \(version)…") {
                    updates.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
            }

            HStack {
                Text("Amplo \(updates.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Rechercher les mises à jour…") {
                    updates.checkForUpdates()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            HStack {
                Button("Diagnostic…") {
                    openWindow(id: "diagnostic")
                    NSApp.activate()
                }
                Spacer()
                Button("Quitter Amplo") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            controller.refreshLoginItemStatus()
        }
    }
}

/// Icône de la barre des menus, qui reflète l'état d'Amplo.
struct MenuBarIcon: View {
    let controller: AmploController

    var body: some View {
        switch controller.status {
        case .running: Image(nsImage: MenuBarSymbol.running)
        case .stopped: Image(nsImage: MenuBarSymbol.stopped)
        case .failed: Image(nsImage: MenuBarSymbol.failed)
        }
    }
}

/// Enceinte suivie d'ondes, assemblées à partir de deux symboles SF en une image « template »
/// (monochrome, adaptée automatiquement au thème de la barre des menus).
@MainActor
enum MenuBarSymbol {
    static let running = image(speaker: "hifispeaker.fill", trailing: "wave.3.right")
    static let stopped = image(speaker: "hifispeaker", trailing: "wave.3.right", trailingOpacity: 0.35)
    static let failed = image(speaker: "hifispeaker", trailing: "xmark")

    static func image(speaker: String, trailing: String, trailingOpacity: CGFloat = 1) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let speakerImage = NSImage(systemSymbolName: speaker, accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
        let trailingImage = NSImage(systemSymbolName: trailing, accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
        let spacing: CGFloat = 1.5
        let size = NSSize(
            width: speakerImage.size.width + spacing + trailingImage.size.width,
            height: max(speakerImage.size.height, trailingImage.size.height)
        )
        let image = NSImage(size: size, flipped: false) { _ in
            speakerImage.draw(in: NSRect(x: 0, y: (size.height - speakerImage.size.height) / 2, width: speakerImage.size.width, height: speakerImage.size.height))
            trailingImage.draw(in: NSRect(
                x: speakerImage.size.width + spacing,
                y: (size.height - trailingImage.size.height) / 2,
                width: trailingImage.size.width,
                height: trailingImage.size.height
            ), from: .zero, operation: .sourceOver, fraction: trailingOpacity)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Amplo"
        return image
    }
}
