import AmploDSP
import CoreAudio
import Foundation

/// Fréquence d'échantillonnage des tests (celle d'un casque Bluetooth).
let sampleRate = 44_100.0

/// Taille d'un cycle d'entrée-sortie, comme l'aggregate device d'Amplo.
let cycleFrames = 512

/// Générateur pseudo-aléatoire à graine fixe (SplitMix64) : des tests reproductibles.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Bruit uniforme entre -1 et 1.
func noise(_ count: Int, seed: UInt64) -> [Float] {
    var generator = SeededGenerator(seed: seed)
    return (0..<count).map { _ in Float.random(in: -1...1, using: &generator) }
}

/// Sinusoïde d'amplitude `amplitude`.
func sine(frequency: Double, amplitude: Float, count: Int, phase: Double = 0) -> [Float] {
    (0..<count).map {
        amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate + phase))
    }
}

/// Positions des canaux décrits par une configuration de buffers entrelacés.
func slots(_ channelsPerBuffer: [Int]) -> [ChannelSlot] {
    channelsPerBuffer.enumerated().flatMap { buffer, channelCount in
        (0..<channelCount).map {
            ChannelSlot(buffer: buffer, channel: $0, channelCount: channelCount)
        }
    }
}

/// Rendu stéréo entrelacé → stéréo entrelacé, comme sur un casque ou des haut-parleurs.
func makeStereoRenderer() -> BoostRenderer {
    let stereo = slots([2])
    return BoostRenderer(
        routes: [
            OutputRoute(destination: stereo[0], source: .tap(stereo[0])),
            OutputRoute(destination: stereo[1], source: .tap(stereo[1])),
        ],
        inputBufferCount: 1,
        outputBufferCount: 1,
        sampleRate: sampleRate,
    )
}

/// Fait passer un signal stéréo dans le rendu, cycle par cycle.
///
/// - Parameters:
///   - renderer: Rendu à tester.
///   - left: Canal gauche capté.
///   - right: Canal droit capté.
///   - gainAt: Gain à appliquer pour chaque cycle, selon son numéro.
/// - Returns: Les canaux gauche et droit envoyés à la sortie.
func render(
    _ renderer: BoostRenderer,
    left: [Float],
    right: [Float],
    gainAt: (Int) -> Float,
) -> (left: [Float], right: [Float]) {
    let inputList = AudioBufferList.allocate(maximumBuffers: 1)
    let outputList = AudioBufferList.allocate(maximumBuffers: 1)
    let inputData = UnsafeMutablePointer<Float>.allocate(capacity: 2 * cycleFrames)
    let outputData = UnsafeMutablePointer<Float>.allocate(capacity: 2 * cycleFrames)
    defer {
        unsafe free(inputList.unsafeMutablePointer)
        unsafe free(outputList.unsafeMutablePointer)
        unsafe inputData.deallocate()
        unsafe outputData.deallocate()
    }

    var outputLeft: [Float] = []
    var outputRight: [Float] = []
    var start = 0
    var cycle = 0
    while start < left.count {
        let count = min(cycleFrames, left.count - start)
        for frame in 0..<count {
            unsafe inputData[2 * frame] = left[start + frame]
            unsafe inputData[2 * frame + 1] = right[start + frame]
        }
        unsafe inputList[0] = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(8 * count),
            mData: inputData,
        )
        unsafe outputList[0] = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(8 * count),
            mData: outputData,
        )
        renderer.setGain(gainAt(cycle))
        unsafe renderer.render(
            input: inputList.unsafePointer,
            output: outputList.unsafeMutablePointer,
        )
        for frame in 0..<count {
            unsafe outputLeft.append(outputData[2 * frame])
            unsafe outputRight.append(outputData[2 * frame + 1])
        }
        start += count
        cycle += 1
    }
    return (outputLeft, outputRight)
}
