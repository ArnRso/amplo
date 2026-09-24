import Darwin

/// Limiteur crête à anticipation, stéréo lié (même gain sur tous les canaux).
///
/// Le son est retardé de `lookahead` : le gain a le temps de descendre *avant* qu'une crête
/// n'arrive, au lieu de la déformer. Chaîne de calcul du gain, frame par frame :
/// 1. gain requis pour ramener la crête de la frame sous le plafond ;
/// 2. minimum de ce gain sur une fenêtre glissante (anticipation + maintien) ;
/// 3. relâchement progressif quand le gain remonte ;
/// 4. moyenne glissante sur la durée d'anticipation, pour une descente sans cassure.
/// Chaque valeur moyennée est inférieure au gain requis par la frame qui sort du retard :
/// la sortie ne dépasse jamais le plafond (à l'arrondi flottant près, quelques 1e-7).
///
/// Mémoire allouée à l'initialisation, `process` est utilisable depuis le thread temps réel.
final class LookaheadLimiter {
    static let ceiling: Float = 0.891  // -1 dBFS : marge pour l'encodage Bluetooth
    static let lookahead = 0.005
    static let hold = 0.020
    static let release = 0.100

    let channelCount: Int
    /// Retard introduit, en frames.
    let latencyFrames: Int

    private let lookaheadFrames: Int
    private let windowFrames: Int
    private let releaseCoefficient: Double

    private let delay: UnsafeMutablePointer<Float>
    private var delayIndex = 0

    private let windowGains: UnsafeMutablePointer<Float>
    private let windowFrameNumbers: UnsafeMutablePointer<Int>
    private var windowStart = 0
    private var windowCount = 0
    private var frameNumber = 0

    /// En Double : en Float, le pas de relâchement finit arrondi à zéro et le gain reste
    /// bloqué juste sous 1 au lieu d'y revenir exactement.
    private var releasedGain: Double = 1

    private let smoothing: UnsafeMutablePointer<Float>
    private var smoothingIndex = 0
    private var smoothingSum: Double

    init(channelCount: Int, sampleRate: Double) {
        self.channelCount = channelCount
        lookaheadFrames = max(Int((Self.lookahead * sampleRate).rounded()), 2)
        windowFrames = lookaheadFrames + Int((Self.hold * sampleRate).rounded())
        latencyFrames = lookaheadFrames - 1
        releaseCoefficient = 1 - exp(-1 / (Self.release * sampleRate))

        delay = .allocate(capacity: lookaheadFrames * channelCount)
        delay.initialize(repeating: 0, count: lookaheadFrames * channelCount)
        windowGains = .allocate(capacity: windowFrames)
        windowFrameNumbers = .allocate(capacity: windowFrames)
        smoothing = .allocate(capacity: lookaheadFrames)
        smoothing.initialize(repeating: 1, count: lookaheadFrames)
        // Somme exacte en Double : des Float entre 0 et 1 s'y additionnent et s'y soustraient
        // sans erreur d'arrondi, le gain revient donc exactement à 1.
        smoothingSum = Double(lookaheadFrames)
    }

    deinit {
        delay.deallocate()
        windowGains.deallocate()
        windowFrameNumbers.deallocate()
        smoothing.deallocate()
    }

    /// Remplace les `channelCount` échantillons de `frame` par ceux sortant du retard, limités.
    /// `isAmplified` à false : la frame n'impose aucune réduction (son d'origine, gain de 100 %).
    /// Renvoie le gain appliqué.
    func process(_ frame: UnsafeMutablePointer<Float>, isAmplified: Bool) -> Float {
        var peak: Float = 0
        for channel in 0..<channelCount {
            peak = max(peak, abs(frame[channel]))
        }
        let required = isAmplified && peak > Self.ceiling ? Self.ceiling / peak : 1

        // Minimum glissant (file monotone) des gains requis sur `windowFrames` frames.
        if windowCount > 0, windowFrameNumbers[windowStart] <= frameNumber - windowFrames {
            windowStart = (windowStart + 1) % windowFrames
            windowCount -= 1
        }
        while windowCount > 0, windowGains[(windowStart + windowCount - 1) % windowFrames] >= required {
            windowCount -= 1
        }
        let back = (windowStart + windowCount) % windowFrames
        windowGains[back] = required
        windowFrameNumbers[back] = frameNumber
        windowCount += 1
        frameNumber += 1
        let held = Double(windowGains[windowStart])

        if held < releasedGain {
            releasedGain = held
        } else {
            releasedGain += (held - releasedGain) * releaseCoefficient
            if held - releasedGain < 1e-5 {
                releasedGain = held
            }
        }

        let smoothed = Float(releasedGain)
        smoothingSum += Double(smoothed) - Double(smoothing[smoothingIndex])
        smoothing[smoothingIndex] = smoothed
        smoothingIndex = (smoothingIndex + 1) % lookaheadFrames
        let gain = Float(smoothingSum / Double(lookaheadFrames))

        // Retard de `latencyFrames` : la case suivante contient la frame la plus ancienne.
        let written = delay + delayIndex * channelCount
        delayIndex = (delayIndex + 1) % lookaheadFrames
        let oldest = delay + delayIndex * channelCount
        for channel in 0..<channelCount {
            written[channel] = frame[channel]
        }
        for channel in 0..<channelCount {
            frame[channel] = oldest[channel] * gain
        }
        return gain
    }
}
