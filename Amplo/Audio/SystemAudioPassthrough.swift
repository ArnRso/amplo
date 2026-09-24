import CoreAudio
import Foundation

/// Capture tout le son du système (sauf Amplo) et le rejoue sur la sortie par défaut.
///
/// Chaîne : tap global qui coupe le son d'origine → aggregate device privé contenant la
/// sortie par défaut et le tap → IOProc qui amplifie le tap vers la sortie (voir BoostRenderer).
final class SystemAudioPassthrough {
    let renderer: BoostRenderer
    let report: [String]

    private let tap: AudioHardwareTap
    private let aggregate: AudioHardwareAggregateDevice
    private let ioProcID: AudioDeviceIOProcID

    init() throws {
        let system = AudioHardwareSystem.shared
        var undo: [() -> Void] = []

        do {
            guard let ownProcess = try attempt("Lecture du processus Amplo", { try system.process(for: getpid()) }) else {
                throw AmploAudioError("Processus Amplo introuvable dans Core Audio : impossible de l'exclure du tap.")
            }
            guard let output = try attempt("Lecture de la sortie par défaut", { try system.defaultOutputDevice }) else {
                throw AmploAudioError("Aucune sortie audio par défaut.")
            }
            let outputUID = try attempt("Lecture de l'UID de la sortie", { try output.uid })

            // 1. Tap global stéréo, sans Amplo (sinon boucle), qui coupe le son d'origine.
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess.id])
            description.name = "Amplo"
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .muted
            guard let tap = try attempt("Création du tap", { try system.makeProcessTap(description: description) }) else {
                throw AmploAudioError("Création du tap : aucun objet renvoyé.")
            }
            undo.append { try? system.destroyProcessTap(tap) }
            let tapUID = try attempt("Lecture de l'UID du tap", { try tap.uid })

            // 2. Aggregate device privé : la sortie comme sous-périphérique principal (horloge), plus le tap.
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Amplo",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID],
                ],
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true],
                ],
            ]
            guard let aggregate = try attempt("Création de l'aggregate device", { try system.makeAggregateDevice(description: composition) }) else {
                throw AmploAudioError("Création de l'aggregate device : aucun objet renvoyé.")
            }
            undo.append { try? system.destroyAggregateDevice(aggregate) }

            // 3. Routage des canaux d'après les formats réels du tap et de la sortie.
            let plan = try attempt("Lecture des formats", { try RoutingPlan(aggregate: aggregate, output: output, tap: tap) })
            let renderer = BoostRenderer(
                routes: plan.routes,
                inputBufferCount: plan.inputBufferCount,
                outputBufferCount: plan.outputBufferCount,
                sampleRate: plan.sampleRate
            )

            // 4. IOProc appelé directement sur le thread temps réel de Core Audio (pas de queue).
            var procID: AudioDeviceIOProcID?
            let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate.id, nil) { _, input, _, output, _ in
                renderer.render(input: input, output: output)
            }
            guard status == noErr, let procID else {
                throw AmploAudioError("Création de l'IOProc", status: status)
            }
            undo.append { AudioDeviceDestroyIOProcID(aggregate.id, procID) }

            var report = plan.report
            let latency = Double(renderer.latencyFrames) / plan.sampleRate * 1000
            report.append("Limiteur : plafond -1 dBFS · anticipation \(latency.formatted(.number.precision(.fractionLength(1)))) ms · relâchement \(Int(LookaheadLimiter.release * 1000)) ms")
            if plan.inputStreamCount > 1 {
                // La sortie a aussi des entrées (micro d'un casque) : on ne lit que le tap, pour ne
                // pas ouvrir le micro ni faire basculer un casque Bluetooth en mode appel.
                let status = Self.enableOnlyLastInputStream(of: aggregate.id, streamCount: plan.inputStreamCount, ioProcID: procID)
                if status != noErr {
                    report.append("⚠︎ Désactivation des entrées inutiles impossible (OSStatus \(status))")
                }
            }

            let startStatus = AudioDeviceStart(aggregate.id, procID)
            guard startStatus == noErr else {
                throw AmploAudioError("Démarrage de l'aggregate device", status: startStatus)
            }

            self.tap = tap
            self.aggregate = aggregate
            self.ioProcID = procID
            self.renderer = renderer
            self.report = report
            for line in report {
                audioLog.notice("\(line, privacy: .public)")
            }
        } catch {
            for step in undo.reversed() {
                step()
            }
            audioLog.error("\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Arrêt dans l'ordre inverse de la construction : IOProc, aggregate device, puis tap.
    /// La destruction du tap rend le son d'origine aux applications.
    func stop() {
        let system = AudioHardwareSystem.shared
        var status = AudioDeviceStop(aggregate.id, ioProcID)
        if status != noErr {
            audioLog.error("Arrêt de l'IOProc : OSStatus \(status)")
        }
        status = AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
        if status != noErr {
            audioLog.error("Destruction de l'IOProc : OSStatus \(status)")
        }
        do {
            try system.destroyAggregateDevice(aggregate)
        } catch {
            audioLog.error("Destruction de l'aggregate device : \(error.localizedDescription, privacy: .public)")
        }
        do {
            try system.destroyProcessTap(tap)
        } catch {
            audioLog.error("Destruction du tap : \(error.localizedDescription, privacy: .public)")
        }
        audioLog.notice("Passthrough arrêté")
    }

    /// Indique au HAL que l'IOProc n'utilise que le dernier flux d'entrée (le tap).
    private static func enableOnlyLastInputStream(of device: AudioObjectID, streamCount: Int, ioProcID: AudioDeviceIOProcID) -> OSStatus {
        let layout = MemoryLayout<AudioHardwareIOProcStreamUsage>.self
        let flagsOffset = layout.offset(of: \.mStreamIsOn)!
        let size = flagsOffset + streamCount * MemoryLayout<UInt32>.stride
        let usage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: layout.alignment)
        defer { usage.deallocate() }

        usage.storeBytes(of: unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self), toByteOffset: layout.offset(of: \.mIOProc)!, as: UnsafeMutableRawPointer.self)
        usage.storeBytes(of: UInt32(streamCount), toByteOffset: layout.offset(of: \.mNumberStreams)!, as: UInt32.self)
        for index in 0..<streamCount {
            let isOn: UInt32 = index == streamCount - 1 ? 1 : 0
            usage.storeBytes(of: isOn, toByteOffset: flagsOffset + index * MemoryLayout<UInt32>.stride, as: UInt32.self)
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(size), usage)
    }
}
