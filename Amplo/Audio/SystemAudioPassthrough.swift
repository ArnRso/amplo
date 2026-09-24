import CoreAudio
import Foundation

/// Capture tout le son du système (sauf Amplo) et le rejoue, amplifié, sur la sortie par défaut.
///
/// Chaîne : tap global qui coupe le son d'origine → étage de sortie (aggregate device privé
/// contenant la sortie par défaut et le tap → IOProc, voir OutputStage et BoostRenderer).
/// Le tap vit pendant toute la session : le son d'origine reste coupé pendant une bascule.
/// L'étage de sortie est reconstruit quand la sortie par défaut change (jack, Bluetooth…).
@MainActor
final class SystemAudioPassthrough {
    /// Appelé après un changement de sortie : nil si l'étage a été reconstruit, sinon l'erreur.
    var onOutputChange: ((Error?) -> Void)?

    private let tap: AudioHardwareTap
    private var stage: OutputStage?
    private var gain: Float
    private var silenceTest: Bool
    private var listener: AudioObjectPropertyListenerBlock?

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var renderer: BoostRenderer? {
        stage?.renderer
    }

    var report: [String] {
        stage?.report ?? []
    }

    init(gain: Float, silenceTest: Bool) throws {
        let system = AudioHardwareSystem.shared
        guard let ownProcess = try attempt("Lecture du processus Amplo", { try system.process(for: getpid()) }) else {
            throw AmploAudioError("Processus Amplo introuvable dans Core Audio : impossible de l'exclure du tap.")
        }

        // Tap global stéréo, sans Amplo (sinon boucle), qui coupe le son d'origine.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess.id])
        description.name = "Amplo"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .muted
        guard let tap = try attempt("Création du tap", { try system.makeProcessTap(description: description) }) else {
            throw AmploAudioError("Création du tap : aucun objet renvoyé.")
        }

        self.tap = tap
        self.gain = gain
        self.silenceTest = silenceTest

        do {
            guard let output = try attempt("Lecture de la sortie par défaut", { try system.defaultOutputDevice }) else {
                throw AmploAudioError("Aucune sortie audio par défaut.")
            }
            stage = try OutputStage(tap: tap, output: output, gain: gain, silenceTest: silenceTest)
        } catch {
            try? system.destroyProcessTap(tap)
            audioLog.error("\(error.localizedDescription, privacy: .public)")
            throw error
        }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.defaultOutputDidChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, listener)
        if status == noErr {
            self.listener = listener
        } else {
            audioLog.error("Écoute des changements de sortie impossible : OSStatus \(status)")
        }
    }

    func setGain(_ gain: Float) {
        self.gain = gain
        stage?.renderer.setGain(gain)
    }

    func setSilenceTest(_ silenceTest: Bool) {
        self.silenceTest = silenceTest
        stage?.renderer.silenceTest.store(silenceTest, ordering: .relaxed)
    }

    /// Arrêt : écoute des changements, étage de sortie, puis tap.
    /// La destruction du tap rend le son d'origine aux applications.
    func stop() {
        if let listener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, listener)
            self.listener = nil
        }
        stage?.stop()
        stage = nil
        do {
            try AudioHardwareSystem.shared.destroyProcessTap(tap)
        } catch {
            audioLog.error("Destruction du tap : \(error.localizedDescription, privacy: .public)")
        }
        audioLog.notice("Passthrough arrêté")
    }

    private func defaultOutputDidChange() {
        do {
            guard let output = try attempt("Lecture de la sortie par défaut", { try AudioHardwareSystem.shared.defaultOutputDevice }) else {
                throw AmploAudioError("Aucune sortie audio par défaut.")
            }
            let outputUID = try attempt("Lecture de l'UID de la sortie", { try output.uid })
            // Plusieurs notifications peuvent arriver pour un même changement.
            guard outputUID != stage?.outputUID else { return }

            audioLog.notice("Nouvelle sortie par défaut : \(outputUID, privacy: .public)")
            stage?.stop()
            stage = nil
            stage = try OutputStage(tap: tap, output: output, gain: gain, silenceTest: silenceTest)
            onOutputChange?(nil)
        } catch {
            audioLog.error("Changement de sortie : \(error.localizedDescription, privacy: .public)")
            onOutputChange?(error)
        }
    }
}
