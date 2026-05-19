import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/**
 * HardwareCaptureManager.swift (Arquitectura v8 - Mic Fix)
 *
 * CAPTURA DIRECTA VÍA AUHAL:
 * - Lee el formato NATIVO del dispositivo (mono/stereo, cualquier sample rate)
 * - Configura el AUHAL con ese formato nativo en lugar de forzar estéreo
 * - El AudioEngine se encarga de la conversión mono→stereo en processAudio()
 *
 * PROBLEMA RESUELTO:
 * Los micrófonos externos suelen ser MONO. Forzar 2 canales causaba que
 * AudioUnitRender fallara silenciosamente (devuelve noErr pero 0 datos).
 */

fileprivate func halInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let session = Unmanaged<CaptureSession>.fromOpaque(inRefCon).takeUnretainedValue()
    return session.render(flags: ioActionFlags, timeStamp: inTimeStamp, busNumber: inBusNumber, frames: inNumberFrames)
}

class HardwareCaptureManager {
    static let shared = HardwareCaptureManager()
    var onAudioBuffer: ((UUID, AVAudioPCMBuffer) -> Void)?
    private var sessions: [UUID: CaptureSession] = [:]
    
    private init() {}
    
    func startCapture(for channelId: UUID, device: AudioDevice, voiceIsolation: Bool = false) {
        stopCapture(for: channelId)
        
        print("🎙️ [Hardware] Iniciando AU HALOutput (Direct) para: \(device.name)")
        
        // [BUG-16] requestAccess debe ejecutarse en el hilo principal para mostrar el diálogo de permisos.
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            print("⚠️ [Hardware] Sin permisos de micrófono. Solicite acceso en Ajustes.")
            DispatchQueue.main.async {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
        }
        
        let session = CaptureSession(channelId: channelId, device: device, manager: self, voiceIsolation: voiceIsolation)
        sessions[channelId] = session
        session.start()
    }
    
    func stopCapture(for channelId: UUID) {
        sessions[channelId]?.stop()
        sessions.removeValue(forKey: channelId)
    }
}

class CaptureSession {
    let device: AudioDevice
    let channelId: UUID
    weak var manager: HardwareCaptureManager?
    
    private var audioUnit: AudioUnit?
    private var isRunning = false
    private let voiceIsolation: Bool
    
    // Buffers pre-asignados para evitar alloc en el render thread
    private var rawBuffer: AVAudioPCMBuffer?
    private var captureFormat: AVAudioFormat?
    
    private var callbackCount = 0
    private var lastCallbackTime: Double = 0
    
    init(channelId: UUID, device: AudioDevice, manager: HardwareCaptureManager, voiceIsolation: Bool = false) {
        self.channelId = channelId
        self.device = device
        self.manager = manager
        self.voiceIsolation = voiceIsolation
    }
    
    func start() {
        // [BUG-01] Leer formato nativo directamente de CoreAudio sin AU intermedia.
        // La AU "dummy" anterior nunca se inicializaba → nativeASBD siempre con ceros.
        var nativeASBD = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var streamAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(device.id, &streamAddr, 0, nil, &asbdSize, &nativeASBD)
        
        let nativeChannels = max(nativeASBD.mChannelsPerFrame, 1)
        let nativeSampleRate = nativeASBD.mSampleRate > 0 ? nativeASBD.mSampleRate : 48000.0
        print("🎙️ [Hardware] Formato nativo leído: \(nativeSampleRate)Hz, \(nativeChannels)ch")
        
        
        // [DSP] Voice Isolation ahora se maneja por DSP en AudioEngine (Noise Gate).
        // Forzamos HALOutput puro para evitar crashes de CoreAudio (-10875) con Aggregate Devices.
        let success = attemptInitAU(subType: kAudioUnitSubType_HALOutput, nativeSampleRate: nativeSampleRate, nativeChannels: nativeChannels)
        if !success { print("⚠️ [Hardware] HALOutput falló al iniciar.") }
    }
    
    private func attemptInitAU(subType: OSType, nativeSampleRate: Double, nativeChannels: UInt32) -> Bool {
        if let au = audioUnit {
            AudioComponentInstanceDispose(au)
            audioUnit = nil
        }
        
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: subType,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        
        guard let component = AudioComponentFindNext(nil, &desc) else { return false }
        AudioComponentInstanceNew(component, &audioUnit)
        guard let au = audioUnit else { return false }
        
        // 1. Habilitar entrada, deshabilitar salida
        var one: UInt32 = 1; var zero: UInt32 = 0
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4)
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4)
        
        // 2. Asignar dispositivo
        var devID = device.id
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID, 4)
        
        // [HARDWARE QUERY] Consultar el rango físico permitido por el chip del micrófono PRIMERO
        var range = AudioValueRange()
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        var rangeAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let rangeStatus = AudioObjectGetPropertyData(devID, &rangeAddr, 0, nil, &rangeSize, &range)
        if rangeStatus == noErr {
            // Mantenimiento posterior: Muestra los límites físicos de hardware del chip
            // print("🔍 [Chip Mic] Límites físicos de \(device.name) -> Mínimo: \(Int(range.mMinimum)) frames (~\(String(format: "%.2f", range.mMinimum/48.0))ms) | Máximo: \(Int(range.mMaximum)) frames")
        }
        
        // [VIRTUAL VS PHYSICAL] Consultar si es un driver virtual para aplicar un buffer seguro más grande (1024 frames)
        var transportType: UInt32 = 0
        var typeSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(devID, &transportAddr, 0, nil, &typeSize, &transportType)
        let isVirtual = (transportType == 1986622068) // 'virt' (kAudioDeviceTransportTypeVirtual)
        
        var bufferSize: UInt32 = 64
        if isVirtual {
            bufferSize = 1024
            // Mantenimiento posterior: Muestra el uso de búfer para dispositivos virtuales
            // print("🎛️ [Hardware] Dispositivo virtual '\(device.name)' detectado. Usando buffer estable de \(bufferSize) frames.")
        } else {
            // [HARDWARE NATIVO ALINEADO] Si el chip soporta 16 o menos, fijamos exactamente 16 frames (~0.33ms).
            // Esto asegura alineación nativa de potencia de 2 en CoreAudio, eliminando jitter de empaquetado.
            if rangeStatus == noErr && range.mMinimum > 0 {
                bufferSize = range.mMinimum <= 16 ? 16 : UInt32(range.mMinimum)
            } else {
                bufferSize = 16
            }
            // Mantenimiento posterior: Muestra la configuración de búfer para dispositivos físicos
            // print("🎙️ [Hardware] Dispositivo físico '\(device.name)' detectado. Configurando buffer a \(bufferSize) frames.")
        }
        
        // [LATENCIA CERO NATIVA] 1. Establecer buffer en Scope Global (Estándar maestro para hardware en macOS)
        var bufferSizeAddrGlobal = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(devID, &bufferSizeAddrGlobal) {
            AudioObjectSetPropertyData(devID, &bufferSizeAddrGlobal, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bufferSize)
        }
        
        // 2. Establecer buffer en Scope de Entrada (Input)
        var bufferSizeAddrInput = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(devID, &bufferSizeAddrInput) {
            AudioObjectSetPropertyData(devID, &bufferSizeAddrInput, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bufferSize)
        }
        
        // 3. Establecer buffer en Scope de Salida (Output)
        var bufferSizeAddrOutput = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(devID, &bufferSizeAddrOutput) {
            AudioObjectSetPropertyData(devID, &bufferSizeAddrOutput, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bufferSize)
        }
        
        // Comprobar tamaño real establecido
        var actualSize: UInt32 = 0
        var actualSizeSize = UInt32(MemoryLayout<UInt32>.size)
        let getStatus = AudioObjectGetPropertyData(devID, &bufferSizeAddrInput, 0, nil, &actualSizeSize, &actualSize)
        if getStatus == noErr {
            // Mantenimiento posterior: Muestra el tamaño real del búfer físico del micrófono establecido por CoreAudio
            // print("🎯 [Hardware] Tamaño REAL de buffer físico de \(device.name): \(actualSize) frames (~\(String(format: "%.1f", Double(actualSize)/48.0))ms)")
        } else {
            print("⚠️ [Hardware] No se pudo comprobar el buffer físico del micrófono: \(getStatus)")
        }
        
        // [BUG-02] Configurar AUHAL con el número de canales NATIVOS del dispositivo.
        // Forzar 2 canales en un mic mono hace que AUHAL sólo llene el canal 0;
        // el canal 1 queda con basura → silencio intermitente en el engine.
        var outputASBD = AudioStreamBasicDescription()
        outputASBD.mSampleRate = 48000.0
        outputASBD.mFormatID = kAudioFormatLinearPCM
        outputASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        outputASBD.mChannelsPerFrame = nativeChannels  // Usar canales nativos, no forzar 2
        outputASBD.mBitsPerChannel = 32
        outputASBD.mFramesPerPacket = 1
        outputASBD.mBytesPerFrame = 4
        outputASBD.mBytesPerPacket = 4
        
        let s1 = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &outputASBD, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if s1 != noErr { print("⚠️ [Hardware] Error al configurar formato Output (\(subType)): \(s1)") }
        
        var maxFrames: UInt32 = 8192
        AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        
        // rawBuffer con los canales nativos del dispositivo.
        // El engine duplica L→R si es mono (AudioEngine.swift onAudioBuffer callback).
        captureFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000.0, channels: nativeChannels, interleaved: false)
        if let fmt = captureFormat {
            rawBuffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 8192)
        }
        
        // 5. Callback
        var callbackStruct = AURenderCallbackStruct(inputProc: halInputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        
        let s2 = AudioUnitInitialize(au)
        let s3 = AudioOutputUnitStart(au)
        if s2 == noErr && s3 == noErr {
            isRunning = true
            let isIsolation = subType == kAudioUnitSubType_VoiceProcessingIO
            print("✅ [Hardware] AU Iniciado para \(device.name) (\(nativeSampleRate)Hz, \(nativeChannels)ch) [Voice Isolation: \(isIsolation ? "ON" : "OFF")]")
            return true
        } else {
            print("❌ [Hardware] Error al iniciar AU (\(subType)): Init:\(s2) Start:\(s3)")
            return false
        }
    }
    
    func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>, busNumber: UInt32, frames: UInt32) -> OSStatus {
        guard isRunning, let au = audioUnit, let pcmBuffer = rawBuffer else { return noErr }
        
        pcmBuffer.frameLength = frames
        let abl = pcmBuffer.mutableAudioBufferList
        let ablPointer = UnsafeMutableAudioBufferListPointer(abl)
        
        // Resetear mDataByteSize para que AUHAL sepa cuánto puede escribir
        let byteSize = frames * 4
        for i in 0..<ablPointer.count {
            ablPointer[i].mDataByteSize = byteSize
        }
        
        let status = AudioUnitRender(au, flags, timeStamp, busNumber, frames, abl)
        
        if status == noErr {
            manager?.onAudioBuffer?(channelId, pcmBuffer)
        } else {
            print("❌ [Hardware] Error AudioUnitRender: \(status) (Device: \(device.name))")
        }
        
        return status
    }
    
    func stop() {
        if isRunning, let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            isRunning = false
        }
    }
}
