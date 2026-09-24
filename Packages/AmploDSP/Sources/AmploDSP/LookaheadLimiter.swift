import Darwin

/// Limiteur crête à anticipation, stéréo lié : même gain sur tous les canaux.
///
/// Le son est retardé de ``lookahead`` : le gain a le temps de descendre *avant* qu'une crête
/// n'arrive, au lieu de la déformer. Chaîne de calcul du gain, frame par frame :
/// 1. gain requis pour ramener la crête de la frame sous le plafond ;
/// 2. minimum de ce gain sur une fenêtre glissante (anticipation + maintien) ;
/// 3. relâchement progressif quand le gain remonte ;
/// 4. moyenne glissante sur la durée d'anticipation, pour une descente sans cassure.
/// Chaque valeur moyennée est inférieure au gain requis par la frame qui sort du retard :
/// la sortie ne dépasse jamais le plafond (à l'arrondi flottant près, quelques 1e-7).
///
/// Mémoire allouée à l'initialisation, ``process(_:isAmplified:)`` est utilisable depuis le
/// thread temps réel.
@safe
public final class LookaheadLimiter {
    /// Plafond de sortie : -1 dBFS, pour garder une marge à l'encodage Bluetooth.
    public static let ceiling: Float = 0.891
    /// Durée d'anticipation, en secondes.
    public static let lookahead = 0.005
    /// Durée de maintien du gain réduit après une crête, en secondes.
    public static let hold = 0.020
    /// Constante de temps du relâchement, en secondes.
    public static let release = 0.100

    /// Nombre de canaux traités à chaque frame.
    public let channelCount: Int
    /// Retard introduit, en frames.
    public let latencyFrames: Int

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

    /// Alloue les tampons du limiteur.
    ///
    /// - Parameters:
    ///   - channelCount: Nombre de canaux traités à chaque frame.
    ///   - sampleRate: Fréquence d'échantillonnage, en hertz.
    public init(channelCount: Int, sampleRate: Double) {
        self.channelCount = channelCount
        lookaheadFrames = max(Int((Self.lookahead * sampleRate).rounded()), 2)
        windowFrames = lookaheadFrames + Int((Self.hold * sampleRate).rounded())
        latencyFrames = lookaheadFrames - 1
        releaseCoefficient = 1 - exp(-1 / (Self.release * sampleRate))

        unsafe delay = .allocate(capacity: lookaheadFrames * channelCount)
        unsafe delay.initialize(repeating: 0, count: lookaheadFrames * channelCount)
        unsafe windowGains = .allocate(capacity: windowFrames)
        unsafe windowFrameNumbers = .allocate(capacity: windowFrames)
        unsafe smoothing = .allocate(capacity: lookaheadFrames)
        unsafe smoothing.initialize(repeating: 1, count: lookaheadFrames)
        // Somme exacte en Double : des Float entre 0 et 1 s'y additionnent et s'y soustraient
        // sans erreur d'arrondi, le gain revient donc exactement à 1.
        smoothingSum = Double(lookaheadFrames)
    }

    deinit {
        unsafe delay.deallocate()
        unsafe windowGains.deallocate()
        unsafe windowFrameNumbers.deallocate()
        unsafe smoothing.deallocate()
    }

    /// Remplace les échantillons d'une frame par ceux qui sortent du retard, limités.
    ///
    /// - Parameters:
    ///   - frame: Les ``channelCount`` échantillons de la frame, remplacés en place.
    ///   - isAmplified: `false` si la frame n'impose aucune réduction (son d'origine, gain de 100 %).
    /// - Returns: Le gain appliqué à la frame sortie.
    public func process(_ frame: UnsafeMutablePointer<Float>, isAmplified: Bool) -> Float {
        var peak: Float = 0
        for channel in 0..<channelCount {
            peak = unsafe max(peak, abs(frame[channel]))
        }
        let required = isAmplified && peak > Self.ceiling ? Self.ceiling / peak : 1

        // Minimum glissant (file monotone) des gains requis sur `windowFrames` frames.
        if windowCount > 0, unsafe windowFrameNumbers[windowStart] <= frameNumber - windowFrames {
            windowStart = (windowStart + 1) % windowFrames
            windowCount -= 1
        }
        while windowCount > 0,
            unsafe windowGains[(windowStart + windowCount - 1) % windowFrames] >= required
        {
            windowCount -= 1
        }
        let back = (windowStart + windowCount) % windowFrames
        unsafe windowGains[back] = required
        unsafe windowFrameNumbers[back] = frameNumber
        windowCount += 1
        frameNumber += 1
        let held = unsafe Double(windowGains[windowStart])

        if held < releasedGain {
            releasedGain = held
        } else {
            releasedGain += (held - releasedGain) * releaseCoefficient
            if held - releasedGain < 1e-5 {
                releasedGain = held
            }
        }

        let smoothed = Float(releasedGain)
        smoothingSum += unsafe Double(smoothed) - Double(smoothing[smoothingIndex])
        unsafe smoothing[smoothingIndex] = smoothed
        smoothingIndex = (smoothingIndex + 1) % lookaheadFrames
        let gain = Float(smoothingSum / Double(lookaheadFrames))

        // Retard de `latencyFrames` : la case suivante contient la frame la plus ancienne.
        let written = unsafe delay + delayIndex * channelCount
        delayIndex = (delayIndex + 1) % lookaheadFrames
        let oldest = unsafe delay + delayIndex * channelCount
        for channel in 0..<channelCount {
            unsafe written[channel] = frame[channel]
        }
        for channel in 0..<channelCount {
            unsafe frame[channel] = oldest[channel] * gain
        }
        return gain
    }
}
