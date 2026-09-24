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

/// Traitement temps réel appelé par l'IOProc de l'aggregate device : routage des canaux,
/// gain, puis limiteur à anticipation.
///
/// Tout ce que lit `render` est figé ou alloué à l'initialisation ; les échanges avec le reste
/// de l'app passent uniquement par des atomiques. Aucune allocation, aucun verrou.
/// `currentGain`, `limiter` et les tampons de travail ne servent qu'au thread temps réel.
final class BoostRenderer: @unchecked Sendable {
    /// Écrit du silence au lieu du son capturé : permet de vérifier qu'il n'y a pas de double son.
    let silenceTest = Atomic<Bool>(false)

    private let targetGainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let inputPeakBits = Atomic<UInt32>(0)
    private let peakBits = Atomic<UInt32>(0)
    private let limiterGainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let cycles = Atomic<UInt64>(0)
    private let routes: UnsafeMutableBufferPointer<OutputRoute>
    private let destinations: UnsafeMutableBufferPointer<Channel>
    private let frame: UnsafeMutablePointer<Float>
    private let limiter: LookaheadLimiter
    private let inputBufferCount: Int
    private let outputBufferCount: Int
    private var currentGain: Float = 1

    init(routes: [OutputRoute], inputBufferCount: Int, outputBufferCount: Int, sampleRate: Double) {
        self.routes = .allocate(capacity: routes.count)
        _ = self.routes.initialize(from: routes)
        destinations = .allocate(capacity: routes.count)
        frame = .allocate(capacity: routes.count)
        limiter = LookaheadLimiter(channelCount: routes.count, sampleRate: sampleRate)
        self.inputBufferCount = inputBufferCount
        self.outputBufferCount = outputBufferCount
    }

    deinit {
        routes.deallocate()
        destinations.deallocate()
        frame.deallocate()
    }

    /// Retard introduit par l'anticipation du limiteur, en frames.
    var latencyFrames: Int {
        limiter.latencyFrames
    }

    /// Gain linéaire : 1 = son d'origine inchangé (seulement retardé), jusqu'à 3. Le changement
    /// est appliqué en rampe sur un buffer pour éviter un clic.
    func setGain(_ gain: Float) {
        targetGainBits.store(gain.bitPattern, ordering: .relaxed)
    }

    /// Crête absolue du son capturé, avant gain, depuis le dernier appel.
    func takeInputPeak() -> Float {
        Float(bitPattern: inputPeakBits.exchange(0, ordering: .relaxed))
    }

    /// Crête absolue écrite en sortie depuis le dernier appel.
    func takePeak() -> Float {
        Float(bitPattern: peakBits.exchange(0, ordering: .relaxed))
    }

    /// Plus petit gain appliqué par le limiteur depuis le dernier appel (1 = aucune réduction).
    func takeLimiterGain() -> Float {
        Float(bitPattern: limiterGainBits.exchange(Float(1).bitPattern, ordering: .relaxed))
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

        // Recopie du tap dans les canaux de sortie, qui servent ensuite de tampon de travail.
        var frameCount = routes.isEmpty ? 0 : Int.max
        for (index, route) in routes.enumerated() {
            guard let destination = Self.channel(route.destination, in: outputs) else {
                Self.silence(outputs)
                return
            }
            Self.copy(route.source, from: inputs, to: destination)
            destinations[index] = destination
            frameCount = min(frameCount, destination.frames)
        }

        let startGain = currentGain
        let targetGain = Float(bitPattern: targetGainBits.load(ordering: .relaxed))
        currentGain = targetGain
        let gainStep = (targetGain - startGain) / Float(frameCount)

        var inputPeak: Float = 0
        var peak: Float = 0
        var limiterGain: Float = 1
        for index in 0..<frameCount {
            let gain = startGain + gainStep * Float(index + 1)
            for channel in 0..<destinations.count {
                let captured = destinations[channel][index]
                inputPeak = max(inputPeak, abs(captured))
                frame[channel] = captured * gain
            }
            limiterGain = min(limiterGain, limiter.process(frame, isAmplified: gain != 1))
            for channel in 0..<destinations.count {
                let sample = frame[channel]
                destinations[channel][index] = sample
                peak = max(peak, abs(sample))
            }
        }

        if inputPeak > Float(bitPattern: inputPeakBits.load(ordering: .relaxed)) {
            inputPeakBits.store(inputPeak.bitPattern, ordering: .relaxed)
        }
        if peak > Float(bitPattern: peakBits.load(ordering: .relaxed)) {
            peakBits.store(peak.bitPattern, ordering: .relaxed)
        }
        if limiterGain < Float(bitPattern: limiterGainBits.load(ordering: .relaxed)) {
            limiterGainBits.store(limiterGain.bitPattern, ordering: .relaxed)
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

    /// Recopie la source dans le canal de sortie et complète la fin par du silence.
    private static func copy(_ source: OutputRoute.Source, from inputs: UnsafeMutableAudioBufferListPointer, to destination: Channel) {
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
        while frame < destination.frames {
            destination[frame] = 0
            frame += 1
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
