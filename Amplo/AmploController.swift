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

    private(set) var status: Status = .stopped
    private(set) var report: [String] = []
    private(set) var levelDB = AmploController.meterFloorDB
    private(set) var ioCycles: UInt64 = 0

    var silenceTest = false {
        didSet { passthrough?.renderer.silenceTest.store(silenceTest, ordering: .relaxed) }
    }

    private var passthrough: SystemAudioPassthrough?
    private var meterTask: Task<Void, Never>?

    func start() {
        guard passthrough == nil else { return }
        do {
            let passthrough = try SystemAudioPassthrough()
            passthrough.renderer.silenceTest.store(silenceTest, ordering: .relaxed)
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
        levelDB = Self.meterFloorDB
        if status == .running {
            status = .stopped
        }
    }

    private func updateMeter() {
        guard let renderer = passthrough?.renderer else { return }
        let peak = renderer.takePeak()
        let peakDB = peak > 0 ? max(20 * log10(peak), Self.meterFloorDB) : Self.meterFloorDB
        // Retombée progressive pour que l'indicateur reste lisible.
        levelDB = max(peakDB, levelDB - 1.5)
        ioCycles = renderer.ioCycleCount
    }
}
