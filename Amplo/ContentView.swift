import AppKit
import SwiftUI

/// Fenêtre de test du POC, remplacée par le menu de la barre des menus à l'étape 5.
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
                meter("Capté (avant gain)", levelDB: controller.inputLevelDB)
                meter("Envoyé à la sortie", levelDB: controller.levelDB)
                HStack {
                    Text("Soft clipping")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(controller.isSoftClipping ? .orange : .secondary.opacity(0.4))
                    Spacer()
                }
                Text("Cycles IO : \(controller.ioCycles)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Gain", selection: $controller.gainPercent) {
                    ForEach(AmploController.gainSteps, id: \.self) { percent in
                        Text("\(percent) %").tag(percent)
                    }
                }
                .pickerStyle(.segmented)
                Text("100 % : copie sans altération")
                    .font(.caption)
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

    private func meter(_ title: String, levelDB: Float) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.1f dBFS", levelDB))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(1 - levelDB / AmploController.meterFloorDB))
        }
    }

    private var isRunning: Bool {
        controller.status == .running
    }

    private var statusLabel: some View {
        let (text, color): (String, Color) = switch controller.status {
        case .stopped: ("Arrêté", .secondary)
        case .running: ("Actif · gain \(controller.gainPercent) %", .green)
        case .failed: ("Erreur", .red)
        }
        return Label {
            Text(text).font(.headline)
        } icon: {
            Circle().fill(color).frame(width: 10, height: 10)
        }
    }
}
