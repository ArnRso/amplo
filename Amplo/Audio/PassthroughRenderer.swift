import CoreAudio
import Synchronization

/// Position d'un canal dans une AudioBufferList : index du buffer, rang du canal dans ce
/// buffer, et nombre de canaux entrelacés dans ce buffer (le pas entre deux frames).
struct ChannelSlot: Equatable {
    let buffer: Int
    let channel: Int
    let channelCount: Int
}

/// Ce que l'on écrit dans un canal de sortie de l'aggregate device.
struct OutputRoute {
    enum Source {
        case silence
        case tap(ChannelSlot)
        /// Moyenne de deux canaux du tap, pour une sortie mono.
        case tapMix(ChannelSlot, ChannelSlot)
    }

    let destination: ChannelSlot
    let source: Source
}

/// Traitement temps réel appelé par l'IOProc de l'aggregate device.
///
/// Tout ce que lit `render` est figé à l'initialisation ; les échanges avec le reste de
/// l'app passent uniquement par des atomiques. Aucune allocation, aucun verrou.
final class PassthroughRenderer: @unchecked Sendable {
    /// Écrit du silence au lieu du son capturé : permet de vérifier qu'il n'y a pas de double son.
    let silenceTest = Atomic<Bool>(false)

    private let peakBits = Atomic<UInt32>(0)
    private let cycles = Atomic<UInt64>(0)
    private let routes: UnsafeMutableBufferPointer<OutputRoute>
    private let inputBufferCount: Int
    private let outputBufferCount: Int

    init(routes: [OutputRoute], inputBufferCount: Int, outputBufferCount: Int) {
        self.routes = .allocate(capacity: routes.count)
        _ = self.routes.initialize(from: routes)
        self.inputBufferCount = inputBufferCount
        self.outputBufferCount = outputBufferCount
    }

    deinit {
        routes.deallocate()
    }

    /// Crête absolue écrite en sortie depuis le dernier appel.
    func takePeak() -> Float {
        Float(bitPattern: peakBits.exchange(0, ordering: .relaxed))
    }

    var ioCycleCount: UInt64 {
        cycles.load(ordering: .relaxed)
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        cycles.add(1, ordering: .relaxed)

        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        guard inputs.count == inputBufferCount,
              outputs.count == outputBufferCount,
              !silenceTest.load(ordering: .relaxed)
        else {
            Self.silence(outputs)
            return
        }

        var peak: Float = 0
        for route in routes {
            guard let destination = Self.channel(route.destination, in: outputs) else { continue }
            var frame = 0
            switch route.source {
            case .silence:
                break
            case .tap(let slot):
                if let source = Self.channel(slot, in: inputs) {
                    let count = min(destination.frames, source.frames)
                    while frame < count {
                        let sample = source[frame]
                        destination[frame] = sample
                        peak = max(peak, abs(sample))
                        frame += 1
                    }
                }
            case .tapMix(let leftSlot, let rightSlot):
                if let left = Self.channel(leftSlot, in: inputs), let right = Self.channel(rightSlot, in: inputs) {
                    let count = min(destination.frames, left.frames, right.frames)
                    while frame < count {
                        let sample = 0.5 * (left[frame] + right[frame])
                        destination[frame] = sample
                        peak = max(peak, abs(sample))
                        frame += 1
                    }
                }
            }
            while frame < destination.frames {
                destination[frame] = 0
                frame += 1
            }
        }

        if peak > Float(bitPattern: peakBits.load(ordering: .relaxed)) {
            peakBits.store(peak.bitPattern, ordering: .relaxed)
        }
    }

    private struct Channel {
        let samples: UnsafeMutablePointer<Float>
        let stride: Int
        let frames: Int

        subscript(frame: Int) -> Float {
            get { samples[frame * stride] }
            nonmutating set { samples[frame * stride] = newValue }
        }
    }

    private static func channel(_ slot: ChannelSlot, in list: UnsafeMutableAudioBufferListPointer) -> Channel? {
        let buffer = list[slot.buffer]
        guard Int(buffer.mNumberChannels) == slot.channelCount, let data = buffer.mData else { return nil }
        return Channel(
            samples: data.assumingMemoryBound(to: Float.self) + slot.channel,
            stride: slot.channelCount,
            frames: Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * slot.channelCount)
        )
    }

    private static func silence(_ list: UnsafeMutableAudioBufferListPointer) {
        for buffer in list {
            buffer.mData?.initializeMemory(as: UInt8.self, repeating: 0, count: Int(buffer.mDataByteSize))
        }
    }
}
