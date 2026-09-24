import Foundation
import Observation

/// État de l'app : démarre / arrête le passthrough et expose le niveau de sortie à l'interface.
@MainActor
@Observable
final class AmploController {
    enum Status: Equatable {
        case stopped
        case running
        case failed(String)
    }

    static let meterFloorDB: Float = -60
    static let gainSteps = [100, 125, 150, 175, 200, 250, 300]

    private(set) var status: Status = .stopped
    private(set) var report: [String] = []
    private(set) var inputLevelDB = AmploController.meterFloorDB
    private(set) var levelDB = AmploController.meterFloorDB
    /// Réduction appliquée par le limiteur, en dB (0 = inactif).
    private(set) var limiterReductionDB: Float = 0
    private(set) var ioCycles: UInt64 = 0

    /// Palier de gain en pourcentage, parmi `gainSteps`.
    var gainPercent = 150 {
        didSet { passthrough?.setGain(gain) }
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
        }
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
