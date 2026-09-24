import AmploDSP
import Foundation
import Testing

@Suite("Limiteur à anticipation")
struct LookaheadLimiterTests {
    @Test(
        "Anticipation de 5 ms, quelle que soit la fréquence",
        arguments: [44_100.0, 48_000.0, 96_000.0],
    )
    func latencyIsFiveMilliseconds(sampleRate: Double) {
        let limiter = LookaheadLimiter(channelCount: 2, sampleRate: sampleRate)
        let milliseconds = Double(limiter.latencyFrames + 1) / sampleRate * 1_000

        #expect(abs(milliseconds - 5) < 0.05)
    }

    @Test("Après une phase limitée, le gain revient exactement à 1")
    func gainReturnsExactlyToUnity() {
        let limiter = LookaheadLimiter(channelCount: 1, sampleRate: sampleRate)
        let frame = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        defer { unsafe frame.deallocate() }

        var gains: [Float] = []
        for index in 0..<Int(sampleRate * 3) {
            let isAmplified = index < 40 * cycleFrames
            unsafe frame.pointee =
                0.9 * Float(sin(2 * .pi * 200 * Double(index) / sampleRate)) * (isAmplified ? 3 : 1)
            unsafe gains.append(limiter.process(frame, isAmplified: isAmplified))
        }

        #expect((gains.min() ?? 1) < 0.5, "la phase amplifiée doit être limitée")
        #expect(gains.suffix(Int(sampleRate)).allSatisfy { $0 == 1 })
    }
}
