import Foundation
import Observation
import ServiceManagement

/// État de l'app : démarre / arrête le passthrough et expose le niveau de sortie à l'interface.
/// Le palier et l'état marche / arrêt choisis par l'utilisateur sont mémorisés.
@MainActor
@Observable
final class AmploController {
    private enum DefaultsKey {
        static let gainPercent = "gainPercent"
        static let isEnabled = "isEnabled"
    }

    enum Status: Equatable {
        case stopped
        case running
        case failed(String)
    }

    static let meterFloorDB: Float = -60
    static let gainSteps = [100, 125, 150, 175, 200, 250, 300]

    private(set) var status: Status = .stopped
    private(set) var report: [String] = []
    private(set) var outputName: String?
    private(set) var inputLevelDB = AmploController.meterFloorDB
    private(set) var levelDB = AmploController.meterFloorDB
    /// Réduction appliquée par le limiteur, en dB (0 = inactif).
    private(set) var limiterReductionDB: Float = 0
    private(set) var ioCycles: UInt64 = 0

    /// Palier de gain en pourcentage, parmi `gainSteps`.
    var gainPercent = AmploController.storedGainPercent() {
        didSet {
            UserDefaults.standard.set(gainPercent, forKey: DefaultsKey.gainPercent)
            passthrough?.setGain(gain)
        }
    }

    /// Interrupteur de l'interface : démarre ou arrête Amplo et mémorise le choix.
    var isEnabled: Bool {
        get { status == .running }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.isEnabled)
            newValue ? start() : stop()
        }
    }

    /// État de l'élément d'ouverture à la connexion (Réglages Système → Ouverture).
    private(set) var loginItemStatus = SMAppService.mainApp.status
    private(set) var loginItemError: String?

    var launchesAtLogin: Bool {
        get { loginItemStatus == .enabled || loginItemStatus == .requiresApproval }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                loginItemError = nil
            } catch {
                loginItemError = error.localizedDescription
            }
            refreshLoginItemStatus()
        }
    }

    var silenceTest = false {
        didSet { passthrough?.setSilenceTest(silenceTest) }
    }

    var gain: Float {
        Float(gainPercent) / 100
    }

    private var passthrough: SystemAudioPassthrough?
    private var meterTask: Task<Void, Never>?

    func start() {
        guard passthrough == nil else { return }
        do {
            let passthrough = try SystemAudioPassthrough(gain: gain, silenceTest: silenceTest)
            passthrough.onOutputChange = { [weak self] error in
                self?.outputDidChange(error: error)
            }
            self.passthrough = passthrough
            report = passthrough.report
            outputName = passthrough.outputName
            status = .running
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    self?.updateMeter()
                }
            }
        } catch {
            report = []
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        meterTask?.cancel()
        meterTask = nil
        passthrough?.stop()
        passthrough = nil
        outputName = nil
        inputLevelDB = Self.meterFloorDB
        levelDB = Self.meterFloorDB
        limiterReductionDB = 0
        if status == .running {
            status = .stopped
        }
    }

    private func outputDidChange(error: Error?) {
        if let error {
            // Plus d'étage de sortie : on arrête tout pour que le tap rende le son d'origine.
            stop()
            status = .failed(error.localizedDescription)
        } else {
            report = passthrough?.report ?? []
            outputName = passthrough?.outputName
        }
    }

    /// L'utilisateur peut changer l'autorisation dans Réglages Système : relu à l'ouverture du menu.
    func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
    }

    /// Au lancement : redémarre Amplo s'il était actif à la dernière fermeture.
    func restoreLastState() {
        if UserDefaults.standard.bool(forKey: DefaultsKey.isEnabled) {
            start()
        }
    }

    private static func storedGainPercent() -> Int {
        let stored = UserDefaults.standard.integer(forKey: DefaultsKey.gainPercent)
        return gainSteps.contains(stored) ? stored : 150
    }

    private func updateMeter() {
        guard let renderer = passthrough?.renderer else { return }
        inputLevelDB = Self.meterLevel(peak: renderer.takeInputPeak(), previous: inputLevelDB)
        levelDB = Self.meterLevel(peak: renderer.takePeak(), previous: levelDB)
        let reductionDB = 20 * log10(renderer.takeLimiterGain())
        limiterReductionDB = min(reductionDB, limiterReductionDB + 1.5)
        ioCycles = renderer.ioCycleCount
    }

    /// Crête en dBFS, avec une retombée progressive pour que l'indicateur reste lisible.
    private static func meterLevel(peak: Float, previous: Float) -> Float {
        let peakDB = peak > 0 ? max(20 * log10(peak), meterFloorDB) : meterFloorDB
        return max(peakDB, previous - 1.5)
    }
}
