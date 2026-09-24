import CoreAudio
import Foundation
import OSLog

let audioLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Amplo", category: "audio")

struct AmploAudioError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }

    init(_ action: String, status: OSStatus) {
        errorDescription =
            "\(action) : échec (OSStatus \(status) \(fourCC(UInt32(bitPattern: status))))"
    }
}

/// Exécute un appel Core Audio en ajoutant le nom de l'étape au message d'erreur.
func attempt<T>(_ action: String, _ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as AudioHardwareError {
        throw AmploAudioError(action, status: error.error)
    }
}

/// Affiche un code Core Audio sous forme de quatre caractères quand c'en est un ('!obj', 'nope'…).
func fourCC(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(value) }
    return "'\(String(decoding: bytes, as: UTF8.self))'"
}

func transportName(_ transportType: UInt32) -> String {
    switch transportType {
    case kAudioDeviceTransportTypeBuiltIn: "intégré"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
    case kAudioDeviceTransportTypeUSB: "USB"
    case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "HDMI / DisplayPort"
    case kAudioDeviceTransportTypeAirPlay: "AirPlay"
    case kAudioDeviceTransportTypeVirtual: "virtuel"
    case kAudioDeviceTransportTypeAggregate: "agrégé"
    default: fourCC(transportType)
    }
}

extension AudioStreamBasicDescription {
    var isFloat32PCM: Bool {
        mFormatID == kAudioFormatLinearPCM && mFormatFlags & kAudioFormatFlagIsFloat != 0
            && mBitsPerChannel == 32
    }

    var summary: String {
        let isFloat = mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isInterleaved = mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let sampleType =
            mFormatID == kAudioFormatLinearPCM
            ? "\(isFloat ? "Float" : "Int")\(mBitsPerChannel)" : fourCC(mFormatID)
        return
            "\(mSampleRate.formatted()) Hz · \(mChannelsPerFrame) canaux · \(sampleType) · \(isInterleaved ? "entrelacé" : "non entrelacé")"
    }
}
