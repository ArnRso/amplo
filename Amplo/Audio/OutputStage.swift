import AmploDSP
import CoreAudio
import Foundation
import OSLog

/// Étage de sortie lié à une sortie physique : aggregate device privé, rendu et IOProc.
///
/// L'aggregate device réunit la sortie et le tap. L'étage est reconstruit à chaque changement
/// de sortie par défaut, le tap restant en place.
///
/// Volontairement non isolé : l'IOProc est créé ici pour ne pas hériter de l'isolation
/// du MainActor, puisqu'il est appelé sur le thread temps réel de Core Audio.
@safe
final class OutputStage {
    let outputUID: String
    let outputName: String
    let renderer: BoostRenderer
    let report: [String]

    private let aggregate: AudioHardwareAggregateDevice
    private let ioProcID: AudioDeviceIOProcID

    init(tap: AudioHardwareTap, output: AudioHardwareDevice, gain: Float, silenceTest: Bool) throws
    {
        let system = AudioHardwareSystem.shared
        var undo: [() -> Void] = []

        do {
            let outputUID = try attempt("Lecture de l'UID de la sortie", { try output.uid })
            let outputName = try attempt("Lecture du nom de la sortie", { try output.name })
            let tapUID = try attempt("Lecture de l'UID du tap", { try tap.uid })

            // Aggregate device privé : la sortie comme sous-périphérique principal (horloge), plus le tap.
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Amplo",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
                ],
            ]
            guard
                let aggregate = try attempt(
                    "Création de l'aggregate device",
                    { try system.makeAggregateDevice(description: composition) },
                )
            else {
                throw AmploAudioError("Création de l'aggregate device : aucun objet renvoyé.")
            }
            undo.append { try? system.destroyAggregateDevice(aggregate) }

            // Routage des canaux d'après les formats réels du tap et de la sortie.
            let plan = try attempt(
                "Lecture des formats",
                { try RoutingPlan(aggregate: aggregate, output: output, tap: tap) },
            )
            let renderer = BoostRenderer(
                routes: plan.routes,
                inputBufferCount: plan.inputBufferCount,
                outputBufferCount: plan.outputBufferCount,
                sampleRate: plan.sampleRate,
            )
            renderer.setGain(gain)
            renderer.setSilenceTest(silenceTest)

            // IOProc appelé directement sur le thread temps réel de Core Audio (pas de queue).
            var procID: AudioDeviceIOProcID?
            let status = unsafe AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate.id, nil) {
                _,
                input,
                _,
                output,
                _ in
                unsafe renderer.render(input: input, output: output)
            }
            guard status == noErr, let procID = unsafe procID else {
                throw AmploAudioError("Création de l'IOProc", status: status)
            }
            undo.append { unsafe AudioDeviceDestroyIOProcID(aggregate.id, procID) }

            var report = plan.report
            let latency = Double(renderer.latencyFrames) / plan.sampleRate * 1000
            report.append(
                "Limiteur : plafond -1 dBFS · anticipation \(latency.formatted(.number.precision(.fractionLength(1)))) ms · relâchement \(Int(LookaheadLimiter.release * 1000)) ms"
            )
            if plan.inputStreamCount > 1 {
                // La sortie a aussi des entrées (micro d'un casque) : on ne lit que le tap, pour ne
                // pas ouvrir le micro ni faire basculer un casque Bluetooth en mode appel.
                let status = unsafe Self.enableOnlyLastInputStream(
                    of: aggregate.id,
                    streamCount: plan.inputStreamCount,
                    ioProcID: procID,
                )
                if status != noErr {
                    report.append(
                        "⚠︎ Désactivation des entrées inutiles impossible (OSStatus \(status))"
                    )
                }
            }

            let startStatus = unsafe AudioDeviceStart(aggregate.id, procID)
            guard startStatus == noErr else {
                throw AmploAudioError("Démarrage de l'aggregate device", status: startStatus)
            }

            self.outputUID = outputUID
            self.outputName = outputName
            self.aggregate = aggregate
            unsafe self.ioProcID = unsafe procID
            self.renderer = renderer
            self.report = report
            for line in report {
                audioLog.notice("\(line, privacy: .public)")
            }
        } catch {
            for step in undo.reversed() {
                step()
            }
            throw error
        }
    }

    /// Arrêt dans l'ordre inverse de la construction : IOProc, puis aggregate device.
    func stop() {
        var status = unsafe AudioDeviceStop(aggregate.id, ioProcID)
        if status != noErr {
            audioLog.error("Arrêt de l'IOProc : OSStatus \(status)")
        }
        status = unsafe AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
        if status != noErr {
            audioLog.error("Destruction de l'IOProc : OSStatus \(status)")
        }
        do {
            try AudioHardwareSystem.shared.destroyAggregateDevice(aggregate)
        } catch {
            audioLog.error(
                "Destruction de l'aggregate device : \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Indique au HAL que l'IOProc n'utilise que le dernier flux d'entrée (le tap).
    private static func enableOnlyLastInputStream(
        of device: AudioObjectID,
        streamCount: Int,
        ioProcID: AudioDeviceIOProcID,
    ) -> OSStatus {
        let layout = unsafe MemoryLayout<AudioHardwareIOProcStreamUsage>.self
        guard let procOffset = unsafe layout.offset(of: \.mIOProc),
            let countOffset = unsafe layout.offset(of: \.mNumberStreams),
            let flagsOffset = unsafe layout.offset(of: \.mStreamIsOn)
        else {
            return kAudioHardwareUnspecifiedError
        }
        let size = flagsOffset + streamCount * MemoryLayout<UInt32>.stride
        let usage = unsafe UnsafeMutableRawPointer.allocate(
            byteCount: size,
            alignment: layout.alignment,
        )
        defer { unsafe usage.deallocate() }

        unsafe usage.storeBytes(
            of: unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self),
            toByteOffset: procOffset,
            as: UnsafeMutableRawPointer.self,
        )
        unsafe usage.storeBytes(
            of: UInt32(streamCount),
            toByteOffset: countOffset,
            as: UInt32.self,
        )
        for index in 0..<streamCount {
            let isOn: UInt32 = index == streamCount - 1 ? 1 : 0
            unsafe usage.storeBytes(
                of: isOn,
                toByteOffset: flagsOffset + index * MemoryLayout<UInt32>.stride,
                as: UInt32.self,
            )
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain,
        )
        return unsafe AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(size), usage)
    }
}
