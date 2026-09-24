import CoreAudio
import Darwin
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

/// Traitement temps réel appelé par l'IOProc de l'aggregate device : routage des canaux,
/// gain, puis soft clipping.
///
/// Tout ce que lit `render` est figé à l'initialisation ; les échanges avec le reste de
/// l'app passent uniquement par des atomiques. Aucune allocation, aucun verrou.
/// `currentGain` n'est lu et écrit que par le thread temps réel.
final class BoostRenderer: @unchecked Sendable {
    /// Au-dessous de ce seuil (≈ -3 dBFS), le signal amplifié passe tel quel ; au-dessus, il est
    /// arrondi par une tangente hyperbolique qui tend vers 1 sans jamais le dépasser.
    static let softClipThreshold: Float = 0.7

    /// Écrit du silence au lieu du son capturé : permet de vérifier qu'il n'y a pas de double son.
    let silenceTest = Atomic<Bool>(false)

    private let targetGainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let peakBits = Atomic<UInt32>(0)
    private let clippedSamples = Atomic<UInt32>(0)
    private let cycles = Atomic<UInt64>(0)
    private let routes: UnsafeMutableBufferPointer<OutputRoute>
    private let inputBufferCount: Int
    private let outputBufferCount: Int
    private var currentGain: Float = 1

    init(routes: [OutputRoute], inputBufferCount: Int, outputBufferCount: Int) {
        self.routes = .allocate(capacity: routes.count)
        _ = self.routes.initialize(from: routes)
        self.inputBufferCount = inputBufferCount
        self.outputBufferCount = outputBufferCount
    }

    deinit {
        routes.deallocate()
    }

    /// Gain linéaire : 1 = bypass (copie bit à bit), jusqu'à 3. Le changement est appliqué
    /// en rampe sur un buffer pour éviter un clic.
    func setGain(_ gain: Float) {
        targetGainBits.store(gain.bitPattern, ordering: .relaxed)
    }

    /// Crête absolue écrite en sortie depuis le dernier appel.
    func takePeak() -> Float {
        Float(bitPattern: peakBits.exchange(0, ordering: .relaxed))
    }

    /// Nombre d'échantillons arrondis par le soft clipping depuis le dernier appel.
    func takeClippedSampleCount() -> UInt32 {
        clippedSamples.exchange(0, ordering: .relaxed)
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

        let startGain = currentGain
        let targetGain = Float(bitPattern: targetGainBits.load(ordering: .relaxed))
        currentGain = targetGain
        let isBypassed = startGain == 1 && targetGain == 1

        var peak: Float = 0
        var clipped: UInt32 = 0
        for route in routes {
            guard let destination = Self.channel(route.destination, in: outputs) else { continue }
            let count = Self.copy(route.source, from: inputs, to: destination)
            if isBypassed {
                for frame in 0..<count {
                    peak = max(peak, abs(destination[frame]))
                }
            } else {
                let gainStep = (targetGain - startGain) / Float(destination.frames)
                for frame in 0..<count {
                    let amplified = destination[frame] * (startGain + gainStep * Float(frame + 1))
                    if abs(amplified) > Self.softClipThreshold {
                        clipped += 1
                    }
                    let sample = Self.softClip(amplified)
                    destination[frame] = sample
                    peak = max(peak, abs(sample))
                }
            }
        }

        if peak > Float(bitPattern: peakBits.load(ordering: .relaxed)) {
            peakBits.store(peak.bitPattern, ordering: .relaxed)
        }
        if clipped > 0 {
            clippedSamples.add(clipped, ordering: .relaxed)
        }
    }

    /// Linéaire jusqu'au seuil, puis tanh : continu et sans cassure de pente au seuil.
    static func softClip(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > softClipThreshold else { return sample }
        let headroom = 1 - softClipThreshold
        let shaped = softClipThreshold + headroom * tanh((magnitude - softClipThreshold) / headroom)
        return sample < 0 ? -shaped : shaped
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

    /// Recopie la source dans le canal de sortie, complète la fin par du silence et renvoie
    /// le nombre de frames recopiées.
    private static func copy(_ source: OutputRoute.Source, from inputs: UnsafeMutableAudioBufferListPointer, to destination: Channel) -> Int {
        var frame = 0
        switch source {
        case .silence:
            break
        case .tap(let slot):
            if let channel = channel(slot, in: inputs) {
                let count = min(destination.frames, channel.frames)
                while frame < count {
                    destination[frame] = channel[frame]
                    frame += 1
                }
            }
        case .tapMix(let leftSlot, let rightSlot):
            if let left = channel(leftSlot, in: inputs), let right = channel(rightSlot, in: inputs) {
                let count = min(destination.frames, left.frames, right.frames)
                while frame < count {
                    destination[frame] = 0.5 * (left[frame] + right[frame])
                    frame += 1
                }
            }
        }
        let copied = frame
        while frame < destination.frames {
            destination[frame] = 0
            frame += 1
        }
        return copied
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
