import Foundation
import CoreAudio

public enum ChannelType: String, CaseIterable, Identifiable, Codable {
    case app = "APLICACIÓN"
    case mic = "MICRÓFONO"
    case hardware = "LÍNEA / HW"
    public var id: String { self.rawValue }
}

public enum AudioSourceID: Codable, Hashable {
    case none
    case hardware(uid: String)
    case application(bundleID: String)
    
    public var isNone: Bool {
        if case .none = self { return true }
        return false
    }
}

public enum AudioOutputBus: String, CaseIterable, Codable {
    case master = "MASTER"
    case streaming = "STREAMING"
    case pfl = "PFL / MON"
}

public struct AudioDevice: Identifiable, Hashable {
    public let id: AudioDeviceID
    public let uid: String // Identificador persistente de CoreAudio
    public let name: String
    public let isInput: Bool
    public let isOutput: Bool
    
    public init(id: AudioDeviceID, uid: String, name: String, isInput: Bool, isOutput: Bool) {
        self.id = id
        self.uid = uid
        self.name = name
        self.isInput = isInput
        self.isOutput = isOutput
    }
    
    public func hash(into hasher: inout Hasher) { hasher.combine(uid) }
    public static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool { lhs.uid == rhs.uid }
}

public struct RadioChannel: Identifiable, Codable, Equatable {
    public let id: UUID
    public let type: ChannelType
    public var name: String
    
    // Persistencia robusta
    public var sourceID: AudioSourceID = .none
    public var selectedSourceDisplayName: String = "Ninguna"
    
    public var volume: Double = 0.8
    public var pan: Double = 0.0
    public var eqMode: Int = 10
    // [BUG-07] Arrays separados por modo de EQ: evita que al cambiar entre 10/15/31 bandas
    // los gains de un modo sobrescriban las frecuencias del otro (el array plano de 31
    // posiciones es compartido y los índices no corresponden entre modos).
    public var eqGains10: [Float] = Array(repeating: 0.0, count: 10)
    public var eqGains15: [Float] = Array(repeating: 0.0, count: 15)
    public var eqGains31: [Float] = Array(repeating: 0.0, count: 31)
    
    /// Propiedad computada: acceso unificado al array del modo activo.
    public var currentEQGains: [Float] {
        get {
            switch eqMode {
            case 10: return eqGains10
            case 15: return eqGains15
            default: return eqGains31
            }
        }
        set {
            switch eqMode {
            case 10: eqGains10 = newValue
            case 15: eqGains15 = newValue
            default: eqGains31 = newValue
            }
        }
    }
    public var isLive: Bool = false
    public var isPFL: Bool = false
    
    // Mejoras de Micro: Ganancia y Filtros de Rango (Gate/Limit)
    public var preGain: Double = 1.0          // 1.0 = 0dB
    public var gateThreshold: Double = -96.0 // dB (Apagado por defecto)
    public var limitThreshold: Double = 0.0  // dB (Apagado por defecto)
    public var isVoiceIsolationEnabled: Bool = false // Cancelación de ruido ambiental y eco
    public var isKaraokeEnabled: Bool = false        // Anulación de voz (Vocal Cancel)
    
    public enum CodingKeys: String, CodingKey { 
        case id, type, name, sourceID, selectedSourceDisplayName, volume, pan, eqMode,
             eqGains10, eqGains15, eqGains31,
             isLive, isPFL, preGain, gateThreshold, limitThreshold, isVoiceIsolationEnabled, isKaraokeEnabled
    }
    
    public init(type: ChannelType, name: String) {
        self.id = UUID()
        self.type = type
        self.name = name
    }
}

public struct EQPreset: Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var gains: [Float] // Soporta hasta 31 bandas
    
    public init(name: String, gains: [Float]) {
        self.id = UUID()
        self.name = name
        self.gains = gains
    }
}

// Metadata estática vs Telemetría en tiempo real
public struct ChannelMonitorSnapshot: Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var type: ChannelType
    public var sourceID: AudioSourceID = .none
    public var sourceDisplayName: String = "Ninguna"
    
    // Estado dinámico
    public var isLive: Bool = false
    public var isPFL: Bool = false
    public var volume: Float = 0.8
    public var isVoiceIsolationEnabled: Bool = false
    public var isKaraokeEnabled: Bool = false
    
    // Telemetría pura (Frecuencia de actualización alta)
    public var qSamples: Int = 0
    public var qReady: Bool = false
    public var inputDbL: Float = -96
    public var inputDbR: Float = -96
    
    public init(id: UUID, name: String, type: ChannelType) {
        self.id = id
        self.name = name
        self.type = type
    }
}

public struct ConsoleState: Codable, Equatable {
    public var micChannels: [RadioChannel] = []
    public var appChannels: [RadioChannel] = []
    public var hwChannels: [RadioChannel] = []
    public var eqPresets: [EQPreset] = []
    
    // Master settings
    public var isOnAir: Bool = false
    public var isMonitoringSynced: Bool = false
    public var volumeStudio: Double = 1.0
    public var volumePhones: Double = 0.8
    public var masterPan: Double = 0.0
    public var pflPan: Double = 0.0
    
    // Persistencia de salidas por UID
    public var selectedOutputStreamingUID: String = ""
    public var selectedOutputGeneralUID: String = ""
    public var selectedOutputPFLUID: String = ""
    
    public var selectedOutputStreamingName: String = "Ninguna"
    public var selectedOutputGeneralName: String = "Ninguna"
    public var selectedOutputPFLName: String = "Ninguna"
    
    // Salidas adicionales (multi-destino) por bus
    public var extraGeneralOutputUIDs: [String] = []
    public var extraGeneralOutputNames: [String] = []
    public var extraPFLOutputUIDs: [String] = []
    public var extraPFLOutputNames: [String] = []
    
    public init() {}
}
