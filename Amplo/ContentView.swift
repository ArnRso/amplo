import AppKit
import SwiftUI

/// Fenêtre de test de l'étape 1, remplacée par le menu de la barre des menus à l'étape 5.
struct ContentView: View {
    @Bindable var controller: AmploController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                statusLabel
                Spacer()
                Button(isRunning ? "Arrêter" : "Démarrer") {
                    isRunning ? controller.stop() : controller.start()
                }
                .keyboardShortcut(.defaultAction)
            }

            if case .failed(let message) = controller.status {
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Niveau envoyé à la sortie")
                    Spacer()
                    Text(String(format: "%.1f dBFS", controller.levelDB))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(1 - controller.levelDB / AmploController.meterFloorDB))
                Text("Cycles IO : \(controller.ioCycles)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Toggle("Test : couper la sortie d'Amplo (le son doit disparaître)", isOn: $controller.silenceTest)
                .disabled(!isRunning)

            GroupBox("Diagnostic") {
                VStack(alignment: .leading, spacing: 4) {
                    if controller.report.isEmpty {
                        Text("Démarrez Amplo pour afficher les formats détectés.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(controller.report.enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Copier le diagnostic") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(controller.report.joined(separator: "\n"), forType: .string)
            }
            .disabled(controller.report.isEmpty)
        }
        .padding(20)
        .frame(width: 520)
    }

    private var isRunning: Bool {
        controller.status == .running
    }

    private var statusLabel: some View {
        let (text, color): (String, Color) = switch controller.status {
        case .stopped: ("Arrêté", .secondary)
        case .running: ("Actif · passthrough 100 %", .green)
        case .failed: ("Erreur", .red)
        }
        return Label {
            Text(text).font(.headline)
        } icon: {
            Circle().fill(color).frame(width: 10, height: 10)
        }
    }
}
