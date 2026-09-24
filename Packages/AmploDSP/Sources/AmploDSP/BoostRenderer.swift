public import CoreAudio
import Synchronization

/// Position d'un canal dans une `AudioBufferList`.
///
/// Indique le buffer, le rang du canal dans ce buffer et le nombre de canaux entrelacés
/// dans ce buffer, c'est-à-dire le pas entre deux frames.
public struct ChannelSlot: Equatable, Sendable {
    /// Index du buffer dans l'`AudioBufferList`.
    public let buffer: Int
    /// Rang du canal dans le buffer.
    public let channel: Int
    /// Nombre de canaux entrelacés dans le buffer.
    public let channelCount: Int

    /// Crée la position d'un canal.
    ///
    /// - Parameters:
    ///   - buffer: Index du buffer dans l'`AudioBufferList`.
    ///   - channel: Rang du canal dans le buffer.
    ///   - channelCount: Nombre de canaux entrelacés dans le buffer.
    public init(buffer: Int, channel: Int, channelCount: Int) {
        self.buffer = buffer
        self.channel = channel
        self.channelCount = channelCount
    }
}

/// Ce que l'on écrit dans un canal de sortie de l'aggregate device.
public struct OutputRoute: Sendable {
    /// Origine des échantillons d'un canal de sortie.
    public enum Source: Sendable {
        /// Canal laissé silencieux.
        case silence
        /// Recopie d'un canal du tap.
        case tap(ChannelSlot)
        /// Moyenne de deux canaux du tap, pour une sortie mono.
        case tapMix(ChannelSlot, ChannelSlot)
    }

    /// Canal de sortie à remplir.
    public let destination: ChannelSlot
    /// Origine des échantillons.
    public let source: Source

    /// Crée une route vers un canal de sortie.
    ///
    /// - Parameters:
    ///   - destination: Canal de sortie à remplir.
    ///   - source: Origine des échantillons.
    public init(destination: ChannelSlot, source: Source) {
        self.destination = destination
        self.source = source
    }
}

/// Traitement temps réel appelé par l'IOProc de l'aggregate device.
///
/// Enchaîne le routage des canaux, le gain, puis le limiteur à anticipation. Tout ce que lit
/// ``render(input:output:)`` est figé ou alloué à l'initialisation ; les échanges avec le reste
/// de l'app passent uniquement par des atomiques. Aucune allocation, aucun verrou.
/// `currentGain`, `limiter` et les tampons de travail ne servent qu'au thread temps réel.
@safe
public final class BoostRenderer: @unchecked Sendable {
    private let silenceTest = Atomic<Bool>(false)
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

    /// Retard introduit par l'anticipation du limiteur, en frames.
    public var latencyFrames: Int {
        limiter.latencyFrames
    }

    /// Nombre de cycles traités par l'IOProc depuis la création.
    public var ioCycleCount: UInt64 {
        cycles.load(ordering: .relaxed)
    }

    /// Prépare le traitement pour une disposition de canaux donnée.
    ///
    /// - Parameters:
    ///   - routes: Contenu de chaque canal de sortie.
    ///   - inputBufferCount: Nombre de buffers attendus en entrée (flux du tap compris).
    ///   - outputBufferCount: Nombre de buffers attendus en sortie.
    ///   - sampleRate: Fréquence d'échantillonnage de l'IOProc, en hertz.
    public init(
        routes: [OutputRoute],
        inputBufferCount: Int,
        outputBufferCount: Int,
        sampleRate: Double,
    ) {
        unsafe self.routes = .allocate(capacity: routes.count)
        _ = unsafe self.routes.initialize(from: routes)
        unsafe destinations = .allocate(capacity: routes.count)
        unsafe frame = .allocate(capacity: routes.count)
        limiter = LookaheadLimiter(channelCount: routes.count, sampleRate: sampleRate)
        self.inputBufferCount = inputBufferCount
        self.outputBufferCount = outputBufferCount
    }

    deinit {
        unsafe routes.deallocate()
        unsafe destinations.deallocate()
        unsafe frame.deallocate()
    }

    /// Fixe le gain linéaire, appliqué en rampe sur un buffer pour éviter un clic.
    ///
    /// - Parameter gain: 1 pour le son d'origine inchangé (seulement retardé), jusqu'à 3.
    public func setGain(_ gain: Float) {
        targetGainBits.store(gain.bitPattern, ordering: .relaxed)
    }

    /// Écrit du silence au lieu du son capturé, pour vérifier qu'il n'y a pas de double son.
    ///
    /// - Parameter isEnabled: `true` pour couper la sortie d'Amplo.
    public func setSilenceTest(_ isEnabled: Bool) {
        silenceTest.store(isEnabled, ordering: .relaxed)
    }

    /// Lit puis remet à zéro la crête du son capturé, avant gain.
    ///
    /// - Returns: La crête absolue depuis le dernier appel.
    public func takeInputPeak() -> Float {
        Float(bitPattern: inputPeakBits.exchange(0, ordering: .relaxed))
    }

    /// Lit puis remet à zéro la crête écrite en sortie.
    ///
    /// - Returns: La crête absolue depuis le dernier appel.
    public func takePeak() -> Float {
        Float(bitPattern: peakBits.exchange(0, ordering: .relaxed))
    }

    /// Lit puis remet à 1 le plus petit gain appliqué par le limiteur.
    ///
    /// - Returns: Le gain minimal depuis le dernier appel (1 = aucune réduction).
    public func takeLimiterGain() -> Float {
        Float(bitPattern: limiterGainBits.exchange(Float(1).bitPattern, ordering: .relaxed))
    }

    /// Traite un cycle d'entrée-sortie : routage, gain, puis limiteur.
    ///
    /// - Parameters:
    ///   - input: Buffers d'entrée de l'aggregate device, dont ceux du tap.
    ///   - output: Buffers de sortie de l'aggregate device, entièrement réécrits.
    public func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
    ) {
        cycles.add(1, ordering: .relaxed)

        let inputs = unsafe UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input)
        )
        let outputs = unsafe UnsafeMutableAudioBufferListPointer(output)

        guard inputs.count == inputBufferCount,
            outputs.count == outputBufferCount,
            !silenceTest.load(ordering: .relaxed)
        else {
            Self.silence(outputs)
            return
        }

        // Recopie du tap dans les canaux de sortie, qui servent ensuite de tampon de travail.
        var frameCount = unsafe routes.isEmpty ? 0 : Int.max
        for index in unsafe routes.indices {
            guard let destination = unsafe Self.channel(routes[index].destination, in: outputs)
            else {
                Self.silence(outputs)
                return
            }
            unsafe Self.copy(routes[index].source, from: inputs, to: destination)
            unsafe destinations[index] = destination
            frameCount = unsafe min(frameCount, destination.frames)
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
            for channel in unsafe destinations.indices {
                let captured = unsafe destinations[channel][index]
                inputPeak = max(inputPeak, abs(captured))
                unsafe frame[channel] = captured * gain
            }
            limiterGain = unsafe min(limiterGain, limiter.process(frame, isAmplified: gain != 1))
            for channel in unsafe destinations.indices {
                let sample = unsafe frame[channel]
                unsafe destinations[channel][index] = sample
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

    /// Vue sur un canal d'un buffer entrelacé.
    @unsafe
    private struct Channel {
        let samples: UnsafeMutablePointer<Float>
        let stride: Int
        let frames: Int

        subscript(frame: Int) -> Float {
            get { unsafe samples[frame * stride] }
            nonmutating set { unsafe samples[frame * stride] = newValue }
        }
    }

    /// Recopie la source dans le canal de sortie et complète la fin par du silence.
    private static func copy(
        _ source: OutputRoute.Source,
        from inputs: UnsafeMutableAudioBufferListPointer,
        to destination: Channel,
    ) {
        var frame = 0
        switch source {
        case .silence:
            break
        case .tap(let slot):
            if let channel = unsafe channel(slot, in: inputs) {
                let count = unsafe min(destination.frames, channel.frames)
                while frame < count {
                    unsafe destination[frame] = channel[frame]
                    frame += 1
                }
            }
        case .tapMix(let leftSlot, let rightSlot):
            if let left = unsafe channel(leftSlot, in: inputs),
                let right = unsafe channel(rightSlot, in: inputs)
            {
                let count = unsafe min(destination.frames, left.frames, right.frames)
                while frame < count {
                    unsafe destination[frame] = 0.5 * (left[frame] + right[frame])
                    frame += 1
                }
            }
        }
        while unsafe frame < destination.frames {
            unsafe destination[frame] = 0
            frame += 1
        }
    }

    private static func channel(_ slot: ChannelSlot, in list: UnsafeMutableAudioBufferListPointer)
        -> Channel?
    {
        let buffer = unsafe list[slot.buffer]
        guard unsafe Int(buffer.mNumberChannels) == slot.channelCount,
            let data = unsafe buffer.mData
        else {
            return nil
        }
        return unsafe Channel(
            samples: data.assumingMemoryBound(to: Float.self) + slot.channel,
            stride: slot.channelCount,
            frames: Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * slot.channelCount),
        )
    }

    private static func silence(_ list: UnsafeMutableAudioBufferListPointer) {
        for index in list.indices {
            let buffer = unsafe list[index]
            unsafe buffer.mData?.initializeMemory(
                as: UInt8.self,
                repeating: 0,
                count: Int(buffer.mDataByteSize),
            )
        }
    }
}
