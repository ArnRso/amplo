import AmploDSP
import CoreAudio

/// Correspondance entre les canaux du tap et ceux de la sortie, déduite des formats réels
/// de l'aggregate device (fréquence, nombre de canaux, entrelacement).
///
/// Côté entrée, l'aggregate expose d'abord les flux d'entrée de la sortie physique
/// (le micro d'un casque Bluetooth, par exemple), puis ceux du tap : le tap est donc
/// le dernier flux d'entrée.
struct RoutingPlan {
    let routes: [OutputRoute]
    let inputBufferCount: Int
    let outputBufferCount: Int
    let inputStreamCount: Int
    /// Fréquence à laquelle tourne l'IOProc, celle de la sortie.
    let sampleRate: Double
    let report: [String]

    init(
        aggregate: AudioHardwareAggregateDevice,
        output: AudioHardwareDevice,
        tap: AudioHardwareTap,
    ) throws {
        var report: [String] = []

        let outputName = try output.name
        let outputTransport = try output.transportType
        let tapFormat = try tap.format
        let aggregateRate = try aggregate.nominalSampleRate
        let bufferFrames = try aggregate.bufferFrameSize
        report.append("Sortie : \(outputName) (\(transportName(outputTransport)))")
        report.append("Tap : \(tapFormat.summary)")
        report.append("Aggregate : \(aggregateRate.formatted()) Hz · buffer \(bufferFrames) frames")

        let streams = try aggregate.streams
        let inputStreams = try streams.filter { try $0.direction == .input }
        let outputStreams = try streams.filter { try $0.direction == .output }
        let inputFormats = try inputStreams.map { try $0.virtualFormat }
        let outputFormats = try outputStreams.map { try $0.virtualFormat }
        for (index, format) in inputFormats.enumerated() {
            let role = index == inputFormats.count - 1 ? "tap" : "entrée de la sortie, ignorée"
            report.append("Flux d'entrée \(index) (\(role)) : \(format.summary)")
        }
        for (index, format) in outputFormats.enumerated() {
            report.append("Flux de sortie \(index) : \(format.summary)")
        }

        guard let tapStreamFormat = inputFormats.last else {
            throw AmploAudioError(
                "L'aggregate device n'expose aucun flux d'entrée : le tap n'y figure pas."
            )
        }
        guard tapStreamFormat.isFloat32PCM else {
            throw AmploAudioError("Format du tap non géré : \(tapStreamFormat.summary)")
        }
        if let format = outputFormats.first(where: { !$0.isFloat32PCM }) {
            throw AmploAudioError("Format de sortie non géré : \(format.summary)")
        }
        // Vérifié à l'écoute (Bluetooth à 44 100 Hz) : l'aggregate rééchantillonne le tap
        // via la compensation de dérive, sans décalage de hauteur ni craquement.
        if let format = outputFormats.first(where: { $0.mSampleRate != tapStreamFormat.mSampleRate }
        ) {
            report.append(
                "Rééchantillonnage du tap par Core Audio : \(tapStreamFormat.mSampleRate.formatted()) Hz → \(format.mSampleRate.formatted()) Hz"
            )
        }
        let outputDeviceInputStreams = try output.streams.filter { try $0.direction == .input }
            .count
        if inputStreams.count != outputDeviceInputStreams + 1 {
            report.append(
                "⚠︎ \(inputStreams.count) flux d'entrée dans l'aggregate, \(outputDeviceInputStreams + 1) attendus"
            )
        }

        let inputConfiguration = unsafe try aggregate.inputStreamConfiguration
        let outputConfiguration = unsafe try aggregate.outputStreamConfiguration
        let inputSlots = unsafe Self.slots(inputConfiguration)
        let outputSlots = unsafe Self.slots(outputConfiguration)
        let tapChannels = Int(tapStreamFormat.mChannelsPerFrame)
        let tapSlots = inputSlots.suffix(tapChannels)
        guard let left = tapSlots.first, inputSlots.count >= tapChannels else {
            throw AmploAudioError("Canaux du tap introuvables dans l'aggregate device.")
        }
        guard !outputSlots.isEmpty else {
            throw AmploAudioError("La sortie \(outputName) n'a aucun canal de sortie.")
        }
        let right = tapSlots.dropFirst().first ?? left

        if outputSlots.count == 1 {
            routes = [
                OutputRoute(
                    destination: outputSlots[0],
                    source: left == right ? .tap(left) : .tapMix(left, right),
                )
            ]
            report.append("Routage : tap G+D → sortie mono")
        } else {
            // Les canaux stéréo préférés sont numérotés à partir de 1.
            let preferred = try output.preferredOutputChannelsForStereo.map { Int($0) - 1 }
            var (leftOut, rightOut) = preferred.count == 2 ? (preferred[0], preferred[1]) : (0, 1)
            if !outputSlots.indices.contains(leftOut) || !outputSlots.indices.contains(rightOut) {
                (leftOut, rightOut) = (0, 1)
            }
            routes = outputSlots.enumerated().map { index, slot in
                let source: OutputRoute.Source =
                    index == leftOut ? .tap(left) : index == rightOut ? .tap(right) : .silence
                return OutputRoute(destination: slot, source: source)
            }
            report.append(
                "Routage : tap G → canal \(leftOut + 1), tap D → canal \(rightOut + 1) sur \(outputSlots.count)"
            )
        }

        self.inputBufferCount = unsafe inputConfiguration.count
        self.outputBufferCount = unsafe outputConfiguration.count
        self.inputStreamCount = inputStreams.count
        self.sampleRate = outputFormats[0].mSampleRate
        self.report = report
    }

    /// Liste à plat des canaux décrits par une configuration de flux (un AudioBuffer par flux).
    private static func slots(_ configuration: [AudioBuffer]) -> [ChannelSlot] {
        unsafe configuration.enumerated().flatMap { index, buffer in
            let channelCount = unsafe Int(buffer.mNumberChannels)
            return (0..<channelCount).map {
                ChannelSlot(buffer: index, channel: $0, channelCount: channelCount)
            }
        }
    }
}
