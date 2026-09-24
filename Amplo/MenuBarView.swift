import AppKit
import SwiftUI

/// Panneau ouvert depuis l'icône de la barre des menus.
struct MenuBarView: View {
    @Bindable var controller: AmploController
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
    }
}

/// Icône de la barre des menus, qui reflète l'état d'Amplo.
struct MenuBarIcon: View {
    let controller: AmploController

    var body: some View {
        switch controller.status {
        case .running: Image(systemName: "speaker.wave.3.fill")
        case .stopped: Image(systemName: "speaker.wave.1")
        case .failed: Image(systemName: "speaker.slash")
        }
    }
}
