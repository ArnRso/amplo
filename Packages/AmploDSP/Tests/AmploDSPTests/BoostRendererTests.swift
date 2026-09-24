import AmploDSP
import CoreAudio
import Foundation
import Testing

/// Plafond du limiteur, à l'arrondi flottant près.
private let ceilingTolerance = LookaheadLimiter.ceiling * (1 + 1e-6)

@Suite("Rendu : routage, gain et limiteur")
struct BoostRendererTests {
    private let latency = makeStereoRenderer().latencyFrames

    @Test("100 % : son d'origine bit à bit, seulement retardé, même au-dessus du plafond")
    func passthroughIsBitExact() {
        let count = 20 * cycleFrames
        let left = noise(count, seed: 1)
        let right = noise(count, seed: 2)
        let output = render(makeStereoRenderer(), left: left, right: right) { _ in 1 }

        #expect((0..<latency).allSatisfy { output.left[$0] == 0 })
        #expect(
            (latency..<count).allSatisfy {
                output.left[$0].bitPattern == left[$0 - latency].bitPattern
            }
        )
        #expect(
            (latency..<count).allSatisfy {
                output.right[$0].bitPattern == right[$0 - latency].bitPattern
            }
        )
    }

    @Test("150 % sur un son calme : exactement ×1,5, limiteur inactif")
    func quietSignalIsScaledExactly() {
        let count = 20 * cycleFrames
        let left = sine(frequency: 440, amplitude: 0.4, count: count)
        let right = sine(frequency: 330, amplitude: 0.4, count: count)
        let renderer = makeStereoRenderer()
        let output = render(renderer, left: left, right: right) { _ in 1.5 }

        #expect(
            (2 * cycleFrames..<count).allSatisfy { output.left[$0] == left[$0 - latency] * 1.5 }
        )
        #expect(renderer.takeLimiterGain() == 1)
    }

    @Test("300 % sur un son fort : jamais au-dessus du plafond, réduction attendue")
    func loudSignalStaysUnderCeiling() {
        let count = Int(sampleRate * 3)
        let left = sine(frequency: 60, amplitude: 0.9, count: count)
        let right = sine(frequency: 1_000, amplitude: 0.9, count: count, phase: 1)
        let renderer = makeStereoRenderer()
        let output = render(renderer, left: left, right: right) { _ in 3 }
        let outputPeak = zip(output.left, output.right).map { max(abs($0), abs($1)) }.max() ?? 0

        #expect(outputPeak <= ceilingTolerance)
        #expect(outputPeak > 0.85, "le limiteur ne doit pas écraser le niveau")
        #expect(abs(renderer.takeLimiterGain() - LookaheadLimiter.ceiling / 2.7) < 0.02)
    }

    @Test("Transitoire soudaine après un silence : l'anticipation empêche tout dépassement")
    func suddenTransientStaysUnderCeiling() {
        let count = Int(sampleRate)
        let burst = (0..<count).map { $0 < count / 2 ? Float(0) : ($0.isMultiple(of: 2) ? 1 : -1) }
        let output = render(makeStereoRenderer(), left: burst, right: burst) { _ in 3 }

        #expect(output.left.allSatisfy { abs($0) <= ceilingTolerance })
    }

    @Test(
        "Bruit plein pot : jamais au-dessus du plafond",
        arguments: [125, 150, 175, 200, 250, 300],
    )
    func fullScaleNoiseStaysUnderCeiling(percent: Int) {
        let count = Int(sampleRate)
        let output = render(
            makeStereoRenderer(),
            left: noise(count, seed: UInt64(percent)),
            right: noise(count, seed: UInt64(percent) + 1),
        ) { _ in Float(percent) / 100 }

        #expect(
            zip(output.left, output.right).allSatisfy { max(abs($0), abs($1)) <= ceilingTolerance }
        )
    }

    @Test("Retour à 100 % après une phase limitée : redevient bit à bit")
    func returnToUnityIsBitExact() {
        let count = Int(sampleRate * 4)
        let left = sine(frequency: 200, amplitude: 0.9, count: count)
        let right = sine(frequency: 300, amplitude: 0.9, count: count)
        let output = render(makeStereoRenderer(), left: left, right: right) { $0 < 40 ? 3 : 1 }

        #expect(
            (count - 20 * cycleFrames..<count).allSatisfy {
                output.left[$0].bitPattern == left[$0 - latency].bitPattern
            }
        )
    }

    @Test("Changement de palier 100 → 300 % : montée progressive, sans saut")
    func gainChangeHasNoJump() {
        let count = 10 * cycleFrames
        let level = [Float](repeating: 0.1, count: count)
        let output = render(makeStereoRenderer(), left: level, right: level) { $0 < 5 ? 1 : 3 }
        let settled = output.left.dropFirst(latency + 1)
        let largestJump = zip(settled, settled.dropFirst()).map { abs($1 - $0) }.max() ?? 0

        #expect(largestJump < 0.001)
        #expect(abs((output.left.last ?? 0) - 0.3) < 1e-6)
    }

    @Test("Test de silence : la sortie est muette")
    func silenceTestMutesOutput() {
        let renderer = makeStereoRenderer()
        renderer.setSilenceTest(true)
        let signal = sine(frequency: 440, amplitude: 0.5, count: 4 * cycleFrames)
        let output = render(renderer, left: signal, right: signal) { _ in 2 }

        #expect(output.left.allSatisfy { $0 == 0 })
        #expect(output.right.allSatisfy { $0 == 0 })
    }

    @Test("Niveaux mesurés : crêtes avant et après gain, cycles comptés")
    func metersReportPeaks() {
        let renderer = makeStereoRenderer()
        let signal = [Float](repeating: 0.2, count: 4 * cycleFrames)
        _ = render(renderer, left: signal, right: signal) { _ in 2 }

        #expect(renderer.takeInputPeak() == 0.2)
        #expect(abs(renderer.takePeak() - 0.4) < 1e-6)
        #expect(renderer.ioCycleCount == 4)
        #expect(renderer.takeInputPeak() == 0, "la lecture remet la crête à zéro")
    }
}

@Suite("Rendu : dispositions de canaux")
struct ChannelLayoutTests {
    @Test("Sortie mono : moyenne des canaux gauche et droit")
    func monoOutputAveragesChannels() {
        let input = slots([2])
        let renderer = BoostRenderer(
            routes: [
                OutputRoute(destination: slots([1])[0], source: .tapMix(input[0], input[1]))
            ],
            inputBufferCount: 1,
            outputBufferCount: 1,
            sampleRate: sampleRate,
        )
        let output = renderOnce(renderer, inputChannels: [2], outputChannels: [1]) { _, channel in
            channel == 0 ? 0.2 : 0.6
        }

        #expect(output[0].dropFirst(renderer.latencyFrames).allSatisfy { $0 == 0.5 * (0.2 + 0.6) })
    }

    @Test("Sortie non entrelacée : un buffer par canal, canal supplémentaire silencieux")
    func nonInterleavedOutput() {
        let input = slots([2])
        let output = slots([1, 1, 1])
        let renderer = BoostRenderer(
            routes: [
                OutputRoute(destination: output[0], source: .tap(input[0])),
                OutputRoute(destination: output[1], source: .tap(input[1])),
                OutputRoute(destination: output[2], source: .silence),
            ],
            inputBufferCount: 1,
            outputBufferCount: 3,
            sampleRate: sampleRate,
        )
        let result = renderOnce(renderer, inputChannels: [2], outputChannels: [1, 1, 1]) {
            _,
            channel in
            channel == 0 ? 0.25 : -0.5
        }
        let latency = renderer.latencyFrames

        #expect(result[0].dropFirst(latency).allSatisfy { $0 == 0.25 })
        #expect(result[1].dropFirst(latency).allSatisfy { $0 == -0.5 })
        #expect(result[2].allSatisfy { $0 == 0 })
    }

    @Test("Disposition inattendue (nombre de buffers) : silence complet")
    func unexpectedLayoutOutputsSilence() {
        let renderer = BoostRenderer(
            routes: [],
            inputBufferCount: 3,
            outputBufferCount: 1,
            sampleRate: sampleRate,
        )
        let result = renderOnce(renderer, inputChannels: [2], outputChannels: [2]) { _, _ in 0.5 }

        #expect(result[0].allSatisfy { $0 == 0 })
    }

    /// Un seul cycle, avec des buffers de dispositions quelconques, gain à 100 %.
    ///
    /// - Parameters:
    ///   - renderer: Rendu à tester.
    ///   - inputChannels: Nombre de canaux de chaque buffer d'entrée.
    ///   - outputChannels: Nombre de canaux de chaque buffer de sortie.
    ///   - value: Valeur de l'échantillon d'entrée, selon le buffer et le canal.
    /// - Returns: Le contenu de chaque buffer de sortie, canaux entrelacés.
    private func renderOnce(
        _ renderer: BoostRenderer,
        inputChannels: [Int],
        outputChannels: [Int],
        value: (Int, Int) -> Float,
    ) -> [[Float]] {
        let inputList = AudioBufferList.allocate(maximumBuffers: inputChannels.count)
        let outputList = AudioBufferList.allocate(maximumBuffers: outputChannels.count)
        var allocations: [UnsafeMutablePointer<Float>] = unsafe []
        defer {
            unsafe free(inputList.unsafeMutablePointer)
            unsafe free(outputList.unsafeMutablePointer)
            for index in unsafe allocations.indices {
                unsafe allocations[index].deallocate()
            }
        }

        for (index, channelCount) in inputChannels.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: channelCount * cycleFrames)
            unsafe allocations.append(data)
            for frame in 0..<cycleFrames {
                for channel in 0..<channelCount {
                    unsafe data[frame * channelCount + channel] = value(index, channel)
                }
            }
            let byteSize = UInt32(4 * channelCount * cycleFrames)
            unsafe inputList[index] = AudioBuffer(
                mNumberChannels: UInt32(channelCount),
                mDataByteSize: byteSize,
                mData: data,
            )
        }
        var outputs: [UnsafeMutablePointer<Float>] = unsafe []
        for (index, channelCount) in outputChannels.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: channelCount * cycleFrames)
            unsafe data.initialize(repeating: 7, count: channelCount * cycleFrames)
            unsafe allocations.append(data)
            unsafe outputs.append(data)
            let byteSize = UInt32(4 * channelCount * cycleFrames)
            unsafe outputList[index] = AudioBuffer(
                mNumberChannels: UInt32(channelCount),
                mDataByteSize: byteSize,
                mData: data,
            )
        }

        unsafe renderer.render(
            input: inputList.unsafePointer,
            output: outputList.unsafeMutablePointer,
        )
        return unsafe zip(outputs, outputChannels).map { data, channelCount in
            unsafe Array(UnsafeBufferPointer(start: data, count: channelCount * cycleFrames))
        }
    }
}
