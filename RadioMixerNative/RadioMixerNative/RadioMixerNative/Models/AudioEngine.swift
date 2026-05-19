import Foundation
import AVFoundation
import Accelerate
import Combine
import AudioToolbox
import CoreAudio
import os.log

/**
 * RadioMixerNative - AudioEngine.swift (Arquitectura BROADCAST v22.0 - HEADLESS RT)
 * 
 * ESTRATEGIA DE ESTABILIDAD FINAL:
 * 1. MODO HEADLESS: Desconectamos AVAudioEngine de la salida física para evitar competencia de hilos.
 * 2. SINGLE OUTPUT PULL: Solo mis sesiones AUHAL extraen audio, eliminando sobrecargas de IOWorkLoop.
 * 3. ROBUST UID: Corrección del ruteo CoreAudio para evitar errores de tamaño de datos.
 */

// MARK: - 1. ATOMIC WRAPPER
final class AtomicValue<T>: @unchecked Sendable {
    private var _value: T
    private var lock = os_unfair_lock()
    init(_ value: T) { self._value = value }
    func store(_ value: T) { os_unfair_lock_lock(&lock); _value = value; os_unfair_lock_unlock(&lock) }
    func load() -> T { os_unfair_lock_lock(&lock); let v = _value; os_unfair_lock_unlock(&lock); return v }
}

// MARK: - 2. RENDER CHANNEL
final class RenderChannel: @unchecked Sendable {
    let id: UUID; let type: ChannelType; let name: String; let queue: LockFreeRingBuffer
    let inputNode: AVAudioSourceNode; let eqNode: AVAudioUnitEQ; let dynamicsNode: AVAudioUnitEffect; 
    let masterSendMixer: AVAudioMixerNode; let pflSendMixer: AVAudioMixerNode
    let isLive = AtomicValue<Int>(0); let isPFL = AtomicValue<Int>(0)
    let volume = AtomicValue<Float>(1.0); let isKaraoke = AtomicValue<Int>(0)
    let atomicPreGain = AtomicValue<Float>(1.0)
    let atomicPan = AtomicValue<Float>(0.0)
    let atomicGateThreshold = AtomicValue<Float>(-96.0)
    let atomicLimitThreshold = AtomicValue<Float>(0.0)
    var isVoiceIsolationEnabled: Bool = false
    var sourceDisplayName: String = "Ninguna"
    private let meterL = UnsafeMutablePointer<Float>.allocate(capacity: 1); private let meterR = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    
    init(id: UUID, type: ChannelType, name: String) {
        let isLowLatency = (type == .mic)
        self.id = id; self.type = type; self.name = name
        self.queue = LockFreeRingBuffer(
            capacityFrames: 65536,
            enableCatchUp: true,
            // [LATENCIA INTEGRADA ULTRA-RÁPIDA] Target 64 (1.3ms) y Max 512 (10.6ms) para micrófonos.
            maxLatency: isLowLatency ? 512 : 16384,
            targetLatency: isLowLatency ? 64 : 4096
        )
        self.eqNode = AVAudioUnitEQ(numberOfBands: 32); self.masterSendMixer = AVAudioMixerNode(); self.pflSendMixer = AVAudioMixerNode()
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        self.dynamicsNode = AVAudioUnitEffect(audioComponentDescription: desc)
        meterL.initialize(to: 0); meterR.initialize(to: 0)
        let q = self.queue; let k = self.isKaraoke; let mL = self.meterL; let mR = self.meterR; let atomicP = self.atomicPan; let apg = self.atomicPreGain
        let renderCount = AtomicValue<Int>(0)
        let startupResetDone = AtomicValue<Bool>(false)
        
        self.inputNode = AVAudioSourceNode { (_, _, frames, abl) -> OSStatus in
            let ablPtr = UnsafeMutableAudioBufferListPointer(abl); let n = Int(frames)
            
            // [LATENCIA DE ENTRADA] Eliminar silenciosamente el backlog de arranque en canales de baja latencia
            if isLowLatency {
                let count = renderCount.load() + 1
                renderCount.store(count)
                if !startupResetDone.load() && count > 150 {
                    startupResetDone.store(true)
                    q.resetToTarget()
                    print("⚡️ [Input] Latencia de inicio para canal (\(name)) alineada a target latency.")
                }
            }
            
            if ablPtr.count >= 2 {
                let pL = ablPtr[0].mData!.assumingMemoryBound(to: Float.self); let pR = ablPtr[1].mData!.assumingMemoryBound(to: Float.self)
                q.dequeue(left: pL, right: pR, frames: n)
                
                // [DSP-PREGAIN] BUG-08: Pre-amplificación real vía vDSP (soporta >1.0x / +12dB)
                var pg = apg.load()
                if pg != 1.0 {
                    vDSP_vsmul(pL, 1, &pg, pL, 1, vDSP_Length(n))
                    vDSP_vsmul(pR, 1, &pg, pR, 1, vDSP_Length(n))
                }
                
                if k.load() == 1 { vDSP_vsub(pR, 1, pL, 1, pL, 1, vDSP_Length(n)); var half: Float = 0.5; vDSP_vsmul(pL, 1, &half, pL, 1, vDSP_Length(n)); memcpy(pR, pL, n * 4) }
                
                // [DSP-PAN] Paneo estéreo lineal nativo en tiempo real
                let pan = atomicP.load()
                if pan != 0.0 {
                    var leftGain = min(1.0, 1.0 - pan)
                    var rightGain = min(1.0, 1.0 + pan)
                    vDSP_vsmul(pL, 1, &leftGain, pL, 1, vDSP_Length(n))
                    vDSP_vsmul(pR, 1, &rightGain, pR, 1, vDSP_Length(n))
                }
                
                var rL: Float = 0; var rR: Float = 0; vDSP_rmsqv(pL, 1, &rL, vDSP_Length(n)); vDSP_rmsqv(pR, 1, &rR, vDSP_Length(n)); mL.pointee = rL; mR.pointee = rR
            }
            return noErr
        }
        for b in eqNode.bands { b.filterType = .parametric; b.bypass = false; b.gain = 0; b.bandwidth = 1.0 }
        
        // Evitar error -10874 si CoreAudio exige procesar >1024 frames, pero mantenemos en 4096
        // para evitar que los plugins (EQ/Dynamics) generen un delay (lookahead) de 1 segundo.
        inputNode.auAudioUnit.maximumFramesToRender = 4096
        eqNode.auAudioUnit.maximumFramesToRender = 4096
        dynamicsNode.auAudioUnit.maximumFramesToRender = 4096
        masterSendMixer.auAudioUnit.maximumFramesToRender = 4096
        pflSendMixer.auAudioUnit.maximumFramesToRender = 4096
    }
    deinit { meterL.deallocate(); meterR.deallocate() }
    func getLevels() -> (Float, Float) { (meterL.pointee, meterR.pointee) }
    /// Calcula frames disponibles en el ring buffer
    func queuedFrames() -> Int {
        let h = queue.availableFrames()
        return h
    }
}

// MARK: - VU TELEMETRY STORE (Separado del Engine para no invalidar todo SwiftUI)
/// ObservableObject dedicado a telemetría de VU meters y monitoreo de señal.
/// Al estar separado de RadioAudioEngine, las actualizaciones a 30Hz de VU
/// solo invalidan las vistas que observan este store (meters), no toda la consola.
@MainActor
class VUTelemetryStore: ObservableObject {
    @Published var masterVULeft = -96.0
    @Published var masterVURight = -96.0
    @Published var pflVULeft = -96.0
    @Published var pflVURight = -96.0
    @Published var channelVULevels: [UUID: (left: Double, right: Double)] = [:]
    @Published var channelMonitor: [UUID: ChannelMonitorSnapshot] = [:]
}

// MARK: - 3. HARDWARE OUTPUT SESSION
final class HardwareOutputSession: @unchecked Sendable {
    // [LATENCIA ULTRA-BAJA] OutputBuffer: Target 128 (2.6ms), Max 16384 para fluidez y tiempo real exigente.
    private var audioUnit: AudioUnit?; private let ring = LockFreeRingBuffer(capacityFrames: 32768, enableCatchUp: true, maxLatency: 16384, targetLatency: 128)
    private var isRunning = false; private let name: String
    private let startupResetDone = AtomicValue<Bool>(false)
    private let renderCount = AtomicValue<Int>(0)
    init(name: String) { self.name = name }
    func getLatencyFrames() -> Int { return ring.availableFrames() }
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) { ring.enqueue(left: left, right: right, frames: frames) }
    @discardableResult
    func start(deviceID: AudioDeviceID) -> Bool {
        if isRunning { stop() }
        var devID = deviceID
        startupResetDone.store(false)
        renderCount.store(0)
        
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { return false }
        AudioComponentInstanceNew(component, &audioUnit); guard let au = audioUnit else { return false }
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
        
        // Buffer de 128 frames (~2.6ms): Tiempo real exigente y ultra estable para reproducción.
        var bufferSize: UInt32 = 128
        
        // 1. Establecer en Scope Global (Estándar maestro en macOS)
        var bufferSizeAddrGlobal = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(devID, &bufferSizeAddrGlobal) {
            AudioObjectSetPropertyData(devID, &bufferSizeAddrGlobal, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bufferSize)
        }
        
        // 2. Establecer en Scope Output (Alineamiento estricto del DAC)
        var bufferSizeAddrOutput = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(devID, &bufferSizeAddrOutput) {
            AudioObjectSetPropertyData(devID, &bufferSizeAddrOutput, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bufferSize)
        }
        
        // Mantenimiento posterior: Muestra el ajuste del buffer de salida
    print("🚀 [Output] Buffer de salida (\(name)) ajustado a \(bufferSize) frames (~\(String(format: "%.1f", Double(bufferSize)/48.0))ms)")
        
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        
        var maxFrames: UInt32 = 8192
        AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        
        var cb = AURenderCallbackStruct(inputProc: { (inRefCon, _, _, _, inNumberFrames, ioData) -> OSStatus in
            let session = Unmanaged<HardwareOutputSession>.fromOpaque(inRefCon).takeUnretainedValue()
            guard let abl = ioData else { return noErr }; let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
            
            // Alineamiento inicial de latencia tras ~3 segundos de estabilidad (150 bloques)
            let count = session.renderCount.load() + 1
            session.renderCount.store(count)
            if !session.startupResetDone.load() && count > 150 {
                session.startupResetDone.store(true)
                session.ring.resetToTarget()
                print("⚡️ [Output] Latencia de inicio para \(session.name) alineada a target latency.")
            }
            
            if ablPtr.count >= 2 { session.ring.dequeue(left: ablPtr[0].mData!.assumingMemoryBound(to: Float.self), right: ablPtr[1].mData!.assumingMemoryBound(to: Float.self), frames: Int(inNumberFrames)) }
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        let initStatus = AudioUnitInitialize(au)
        let startStatus = AudioOutputUnitStart(au)
        
        if initStatus == noErr && startStatus == noErr {
            isRunning = true
            print("✅ [Output] Sesión \(name) iniciada en ID \(devID)")
            return true
        } else {
            print("❌ [Output] Error iniciando AUHAL para \(name). init=\(initStatus), start=\(startStatus)")
            stop()
            return false
        }
    }
    func stop() { if isRunning, let au = audioUnit { AudioOutputUnitStop(au); AudioUnitUninitialize(au); AudioComponentInstanceDispose(au); isRunning = false }; audioUnit = nil }
    deinit { stop() }
}

// MARK: - 4. AUDIO ENGINE CORE
final class AudioEngineCore: @unchecked Sendable {
    /// Máximo de destinos adicionales soportados por cada bus (GENERAL o PFL)
    static let maxExtraOutputs = 4
    
    let engine = AVAudioEngine(); let registry = ChannelRegistry()
    let masterMixer = AVAudioMixerNode(); let pflMixer = AVAudioMixerNode()
    let masterOutput = HardwareOutputSession(name: AudioOutputBus.master.rawValue)
    let streamingOutput = HardwareOutputSession(name: AudioOutputBus.streaming.rawValue)
    let pflOutput = HardwareOutputSession(name: AudioOutputBus.pfl.rawValue)
    
    // Slots pre-asignados para salidas extra (multi-destino). El tap los recorre
    // de forma lock-free usando el contador atómico correspondiente.
    let extraMasterOutputs: [HardwareOutputSession] = (0..<AudioEngineCore.maxExtraOutputs).map {
        HardwareOutputSession(name: "GENERAL-extra-\($0)")
    }
    let extraPflOutputs: [HardwareOutputSession] = (0..<AudioEngineCore.maxExtraOutputs).map {
        HardwareOutputSession(name: "PFL-extra-\($0)")
    }
    /// Número de slots extra actualmente iniciados (escritura en Main, lectura en RT tap).
    let atomicExtraMasterCount = AtomicValue<Int>(0)
    let atomicExtraPflCount = AtomicValue<Int>(0)
    
    let atomicMasterVULeft = AtomicValue<Float>(0); let atomicMasterVURight = AtomicValue<Float>(0); let atomicPFLVULeft = AtomicValue<Float>(0); let atomicPFLVURight = AtomicValue<Float>(0)
    let atomicIsOnAir = AtomicValue<Int>(0)
    let atomicMasterPan = AtomicValue<Float>(0.0)
    let atomicPflPan = AtomicValue<Float>(0.0)
    // [BUG-04] Contador monotónico de buses: evita colisiones tras eliminación de canales.
    var nextBusIndex: Int = 0
    
    init() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let silenceEQ = AVAudioUnitEQ(numberOfBands: 1)
        silenceEQ.globalGain = -96.0 // -96dB muting to avoid smart-bypass of 0.0 volume
        
        engine.attach(masterMixer); engine.attach(pflMixer); engine.attach(silenceEQ)
        
        engine.connect(masterMixer, to: engine.mainMixerNode, format: format)
        engine.connect(pflMixer, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: silenceEQ, format: format)
        engine.connect(silenceEQ, to: engine.outputNode, format: format)
        
        engine.mainMixerNode.outputVolume = 1.0
        
        // Evitar error -10874 pero limitando el lookahead de los plugins
        silenceEQ.auAudioUnit.maximumFramesToRender = 4096
        masterMixer.auAudioUnit.maximumFramesToRender = 4096
        pflMixer.auAudioUnit.maximumFramesToRender = 4096
        engine.mainMixerNode.auAudioUnit.maximumFramesToRender = 4096
        silenceEQ.auAudioUnit.maximumFramesToRender = 4096
        engine.outputNode.auAudioUnit.maximumFramesToRender = 4096
        
        let mOut = masterOutput; let pOut = pflOutput
        let extraMOuts = extraMasterOutputs; let extraMCount = atomicExtraMasterCount
        let extraPOuts = extraPflOutputs;  let extraPCount = atomicExtraPflCount
        let amL = atomicMasterVULeft; let amR = atomicMasterVURight; let apL = atomicPFLVULeft; let apR = atomicPFLVURight; let air = atomicIsOnAir
        let amp = atomicMasterPan; let app = atomicPflPan
        
        masterMixer.installTap(onBus: 0, bufferSize: 256, format: format) { (buffer, _) in
            let pL = buffer.floatChannelData![0]; let pR = buffer.floatChannelData![1]; let f = Int(buffer.frameLength)
            
            // [DSP-PAN] Aplicar balance Master en tiempo real
            let pan = amp.load()
            if pan != 0.0 {
                var leftGain = min(1.0, 1.0 - pan)
                var rightGain = min(1.0, 1.0 + pan)
                vDSP_vsmul(pL, 1, &leftGain, pL, 1, vDSP_Length(f))
                vDSP_vsmul(pR, 1, &rightGain, pR, 1, vDSP_Length(f))
            }
            
            // El botón AL AIRE / FUERA DE AIRE controla la mezcla hacia la salida física GENERAL (mOut).
            // Si está FUERA DE AIRE, la salida general se silencia por completo (no se escribe nada).
            if air.load() == 1 {
                mOut.write(left: pL, right: pR, frames: f)
                // Multi-destino: enviar también a cada salida extra de GENERAL activa
                let n = extraMCount.load()
                for i in 0..<n { extraMOuts[i].write(left: pL, right: pR, frames: f) }
            }
            var rL: Float = 0; var rR: Float = 0; vDSP_rmsqv(pL, 1, &rL, vDSP_Length(f)); vDSP_rmsqv(pR, 1, &rR, vDSP_Length(f)); amL.store(rL); amR.store(rR)
            MasterRecorder.shared.write(buffer: buffer)
        }
        pflMixer.installTap(onBus: 0, bufferSize: 256, format: format) { (buffer, _) in
            let pL = buffer.floatChannelData![0]; let pR = buffer.floatChannelData![1]; let f = Int(buffer.frameLength)
            
            // [DSP-PAN] Aplicar balance PFL en tiempo real
            let pan = app.load()
            if pan != 0.0 {
                var leftGain = min(1.0, 1.0 - pan)
                var rightGain = min(1.0, 1.0 + pan)
                vDSP_vsmul(pL, 1, &leftGain, pL, 1, vDSP_Length(f))
                vDSP_vsmul(pR, 1, &rightGain, pR, 1, vDSP_Length(f))
            }
            
            pOut.write(left: pL, right: pR, frames: f)
            // Multi-destino: enviar también a cada salida extra de PFL activa (audífonos adicionales)
            let n = extraPCount.load()
            for i in 0..<n { extraPOuts[i].write(left: pL, right: pR, frames: f) }
            var rL: Float = 0; var rR: Float = 0; vDSP_rmsqv(pL, 1, &rL, vDSP_Length(f)); vDSP_rmsqv(pR, 1, &rR, vDSP_Length(f)); apL.store(rL); apR.store(rR)
        }
        // HEADLESS RT: Forzar la salida del engine al dispositivo físico integrado del Mac
        // ANTES de iniciar. Esto evita que AVAudioEngine use drivers virtuales (AudioAG, Radio Mixer)
        // cuyo HALC_ProxyIOContext no puede sostener el ciclo I/O del engine → IOWorkLoop overloads.
        // La silenceEQ a -96dB garantiza que no se escuche nada por los altavoces integrados.
        // El audio real sale exclusivamente por las sesiones AUHAL (masterOutput, pflOutput).
        if let builtInID = AudioEngineCore.findBuiltInOutputDeviceID(),
           let au = engine.outputNode.audioUnit {
            var devID = builtInID
            
            // [SAMPLE RATE SYNC] Sincronizar el dispositivo físico a 48000Hz
            // AVAudioEngine hereda la frecuencia de este dispositivo. Si el Mac está en 44.1kHz,
            // el engine produce a 44.1kHz pero las salidas (HardwareOutputSession) consumen a 48kHz,
            // causando un rápido vaciado de los buffers y cortes de audio constantes.
            var nominalRate: Float64 = 48000.0
            var rateAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            // Solo intentamos setear la frecuencia si es posible (evita error 'nope' 1852797029)
            var settable: DarwinBoolean = false
            AudioObjectIsPropertySettable(devID, &rateAddr, &settable)
            if settable.boolValue {
                AudioObjectSetPropertyData(devID, &rateAddr, 0, nil, UInt32(MemoryLayout<Float64>.size), &nominalRate)
            }
            
            // macOS integrado se configura a 1024 frames de forma estable.
            // Esto obliga a AVAudioEngine a inicializar internamente todos los recursos de renderizado
            // (mMaxFramesPerSlice) en al menos 1024 frames. De este modo, si ocurre una sobrecarga de CPU,
            // el motor procesará los picos de 1024 frames sin colapsar con error -10874.
            var bufferSize: UInt32 = 1024
            var bufferSizeAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectSetPropertyData(devID, &bufferSizeAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bufferSize)

            let setStatus = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if setStatus == noErr {
                // Mantenimiento posterior: Indica que el motor forzó la salida al dispositivo integrado
                print("🔇 [Engine] Output forzado al dispositivo integrado (ID \(builtInID)) a 48kHz / 1024 frames")
            }
        }
        do { try engine.start(); print("🚀 [Engine] Motor RT-CORE iniciado (Modo Headless)") } catch { print("❌ [Engine] Fallo: \(error.localizedDescription)") }
    }
    
    static func findBuiltInOutputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        
        for id in ids {
            var transportType: UInt32 = 0
            var typeSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            let status = AudioObjectGetPropertyData(id, &transportAddr, 0, nil, &typeSize, &transportType)
            if status == noErr && transportType == kAudioDeviceTransportTypeBuiltIn {
                // Ensure it has output streams
                var streamAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreams,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                )
                var streamSize: UInt32 = 0
                if AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize) == noErr && streamSize > 0 {
                    return id
                }
            }
        }
        
        // Fallback: buscar cualquier dispositivo físico (no virtual)
        for id in ids {
            var transportType: UInt32 = 0
            var typeSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyData(id, &transportAddr, 0, nil, &typeSize, &transportType)
            
            // kAudioDeviceTransportTypeVirtual = 'virt' = 1986622068
            if transportType != 1986622068 {
                var streamAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreams,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                )
                var streamSize: UInt32 = 0
                if AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize) == noErr && streamSize > 0 {
                    return id
                }
            }
        }
        
        return nil
    }
}

// MARK: - 5. UI WRAPPER
@MainActor
class RadioAudioEngine: ObservableObject {
    let core = AudioEngineCore()
    @Published public var volumeStudio = 1.0; @Published public var volumePhones = 0.8
    @Published public var channelOrder: [UUID] = []; @Published public var inputDevices: [AudioDevice] = []; @Published public var outputDevices: [AudioDevice] = []
    @Published public var onAirStartDate: Date? = nil
    @Published public var isEngineStarted = true; @Published public var isOnAir = false {
        didSet {
            core.atomicIsOnAir.store(isOnAir ? 1 : 0)
            if isOnAir {
                onAirStartDate = Date()
            } else {
                onAirStartDate = nil
            }
        }
    }
    @Published public var masterPan = 0.0; @Published public var pflPan = 0.0; @Published public var isMonitoringSynced = true
    @Published public var selectedOutputStreamingUID = ""; @Published public var selectedOutputGeneralUID = ""; @Published public var selectedOutputPFLUID = ""
    
    /// Salidas adicionales activas por bus [(uid, displayName)]
    @Published public var extraGeneralOutputs: [(uid: String, name: String)] = []
    @Published public var extraPFLOutputs: [(uid: String, name: String)] = []
    
    /// Telemetría VU separada: las vistas que solo muestran meters observan este store,
    /// evitando que las actualizaciones a 30Hz invaliden toda la consola.
    public let vuStore = VUTelemetryStore()
    

    public let eqFrequencies: [Int: [Float]] = [10: [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000], 15: [25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 16000], 31: [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000]]
    
    public init() {
        // [FIX-OVERLOAD] Eliminar el scanDevices() de init: el pipeline de persistencia
        // lo llama nuevamente tras iniciar el engine, causando un doble scan en cascada
        // que generaba IOWorkLoop overloads en todos los drivers virtuales.
        // La lista de dispositivos es vacía hasta que el pipeline de restauración se complete.
        startTelemetry()
        
        // [HOTPLUGGING] Registrar observador reactivo para cambios de hardware de CoreAudio
        var systemAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &systemAddress,
            { (inObjectID, inNumberAddresses, inAddresses, inClientData) -> OSStatus in
                if let ptr = inClientData {
                    let engine = Unmanaged<RadioAudioEngine>.fromOpaque(ptr).takeUnretainedValue()
                    DispatchQueue.main.async {
                        print("🔌 [CoreAudio] Dispositivo conectado/desconectado detectado. Escaneando hardware...")
                        engine.scanDevices()
                    }
                }
                return noErr
            },
            selfPtr
        )
        
        HardwareCaptureManager.shared.onAudioBuffer = { [weak self] (id, buffer) in
            guard let self = self else { return }
            guard let l = buffer.floatChannelData?[0] else { return }
            let r = buffer.format.channelCount > 1 ? buffer.floatChannelData![1] : l
            let frameLength = Int(buffer.frameLength)
            
            if let ch = self.core.registry.getChannel(id) {
                // [ADAPTIVE LATENCY] Adaptar dinámicamente los thresholds de la cola
                // al tamaño de bloque físico real que está entregando el chip.
                if ch.type == .mic && ch.queue.targetLatency != 128 {
                    let newTarget = max(frameLength, 128)
                    let newMax = newTarget * 4
                    ch.queue.updateThresholds(target: newTarget, max: newMax)
                    // Mantenimiento posterior: Muestra la adaptación dinámica del búfer de micrófono al chip físico
                    print("⚡️ [Adaptive DSP] Canal Mic '\(ch.name)' adaptado al búfer físico del chip con target de seguridad: \(newTarget) frames (~\(String(format: "%.2f", Double(newTarget)/48.0))ms)")
                }
                ch.queue.enqueue(left: l, right: r, frames: frameLength)
            }
        }
        // [BUG-03] Acceso seguro a floatChannelData: evita crash si el buffer de App es mono.
        AppCaptureManager.shared.onAudioBuffer = { [weak self] (id, buffer) in
            guard let l = buffer.floatChannelData?[0] else { return }
            let r = buffer.format.channelCount > 1 ? buffer.floatChannelData![1] : l
            self?.core.registry.getChannel(id)?.queue.enqueue(left: l, right: r, frames: Int(buffer.frameLength))
        }
    }
    public func createNewChannelNode(id: UUID, type: ChannelType, name: String) {
        let wasRunning = core.engine.isRunning
        if wasRunning { core.engine.stop() }
        
        let ch = RenderChannel(id: id, type: type, name: name)
        core.engine.attach(ch.inputNode); core.engine.attach(ch.eqNode); core.engine.attach(ch.dynamicsNode); core.engine.attach(ch.masterSendMixer); core.engine.attach(ch.pflSendMixer)
        
        // [DEFENSA CRÍTICA] Reaplicar límite máximo de frames MIENTRAS el motor está detenido.
        // Si no detenemos el motor, AVAudioEngine lanza "Cannot set maximumFramesToRender while render resources allocated"
        // y fuerza silenciosamente el bloque a 128 frames, causando crashes -10874 cuando hay picos de CPU (1024 frames).
        ch.inputNode.auAudioUnit.maximumFramesToRender = 4096
        ch.eqNode.auAudioUnit.maximumFramesToRender = 4096
        ch.dynamicsNode.auAudioUnit.maximumFramesToRender = 4096
        ch.masterSendMixer.auAudioUnit.maximumFramesToRender = 4096
        ch.pflSendMixer.auAudioUnit.maximumFramesToRender = 4096
        
        // [DSP] Inicializar Gate/Limiter
        ch.dynamicsNode.bypass = true // [LATENCIA CERO] Completamente apagado por defecto
        if let tree = ch.dynamicsNode.auAudioUnit.parameterTree {
            tree.parameter(withAddress: 3)?.value = -120.0 // Gate apagado
            tree.parameter(withAddress: 2)?.value = 1.0    // Ratio 1:1
            tree.parameter(withAddress: 0)?.value = -2.0   // Limitador en -2dB
            tree.parameter(withAddress: 1)?.value = 3.0    // Headroom
            tree.parameter(withAddress: 4)?.value = 0.001  // Attack rápido
        }
        
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        core.engine.connect(ch.inputNode, to: ch.eqNode, format: format)
        core.engine.connect(ch.eqNode, to: ch.dynamicsNode, format: format)
        
        // Fan-out from dynamics to both send mixers
        let connectionPoints = [
            AVAudioConnectionPoint(node: ch.masterSendMixer, bus: 0),
            AVAudioConnectionPoint(node: ch.pflSendMixer, bus: 0)
        ]
        core.engine.connect(ch.dynamicsNode, to: connectionPoints, fromBus: 0, format: format)
        
        // [BUG-04] Bus monotónico: evita colisión de índices tras borrar/recrear canales.
        let bus = core.nextBusIndex
        core.nextBusIndex += 1
        core.engine.connect(ch.masterSendMixer, to: core.masterMixer, fromBus: 0, toBus: bus, format: format)
        core.engine.connect(ch.pflSendMixer, to: core.pflMixer, fromBus: 0, toBus: bus, format: format)
        
        core.registry.register(ch)
        self.channelOrder = core.registry.snapshot().map { $0.id }
        updateGains(ch)
        
        if wasRunning { try? core.engine.start() }
    }
    public func deleteChannelNode(for id: UUID) {
        guard let ch = core.registry.getChannel(id) else { return }
        let wasRunning = core.engine.isRunning
        if wasRunning { core.engine.stop() }
        
        core.engine.disconnectNodeInput(ch.inputNode); core.engine.disconnectNodeInput(ch.eqNode); core.engine.disconnectNodeInput(ch.dynamicsNode); core.engine.disconnectNodeInput(ch.masterSendMixer); core.engine.disconnectNodeInput(ch.pflSendMixer)
        core.engine.detach(ch.inputNode); core.engine.detach(ch.eqNode); core.engine.detach(ch.dynamicsNode); core.engine.detach(ch.masterSendMixer); core.engine.detach(ch.pflSendMixer)
        
        core.registry.unregister(id: id)
        self.channelOrder = core.registry.snapshot().map { $0.id }
        vuStore.channelMonitor.removeValue(forKey: id)
        
        if wasRunning { try? core.engine.start() }
    }
    public func setVolume(_ vol: Double, for id: UUID) { if let ch = core.registry.getChannel(id) { ch.volume.store(Float(vol)); updateGains(ch) } }
    public func setPan(_ pan: Double, for id: UUID) { if let ch = core.registry.getChannel(id) { ch.atomicPan.store(Float(pan)) } }
    public func setLive(_ live: Bool, for id: UUID) { if let ch = core.registry.getChannel(id) { ch.isLive.store(live ? 1 : 0); updateGains(ch) } }
    public func setPFL(_ pfl: Bool, for id: UUID) { if let ch = core.registry.getChannel(id) { ch.isPFL.store(pfl ? 1 : 0); updateGains(ch) } }
    public func setKaraoke(_ enabled: Bool, for id: UUID) { core.registry.getChannel(id)?.isKaraoke.store(enabled ? 1 : 0) }
    public func updateEQ(gains: [Float], mode: Int, for id: UUID) { guard let ch = core.registry.getChannel(id) else { return }; let freqs = eqFrequencies[mode] ?? []; for i in 0..<min(gains.count, ch.eqNode.bands.count, freqs.count) { let band = ch.eqNode.bands[i]; band.frequency = freqs[i]; band.gain = gains[i] } }
    private func updateGains(_ ch: RenderChannel) { 
        let live = ch.isLive.load() == 1; let pfl = ch.isPFL.load() == 1
        let vol = ch.volume.load()
        // [BUG-06] Usar 0.0 real: AVAudioEngine ≥ macOS 13 aplica bypass correcto sin artefactos.
        ch.masterSendMixer.outputVolume = live ? vol : 0.0
        ch.pflSendMixer.outputVolume = pfl ? vol : 0.0
    }
    
    private func startTelemetry() {
        // [BUG-15] RunLoop.main explícito: garantiza que el timer dispare incluso si init()
        // se mueve a un contexto diferente en futuras refactorizaciones.
        let timer = Timer(timeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let mL = self.core.atomicMasterVULeft.load(); let mR = self.core.atomicMasterVURight.load()
            let pL = self.core.atomicPFLVULeft.load(); let pR = self.core.atomicPFLVURight.load()
            let channels = self.core.registry.snapshot()
            
            // Precalcular VU en dB y snapshots de monitoreo fuera del hilo principal
            var vu: [UUID: (left: Double, right: Double)] = [:]
            var monitors: [UUID: ChannelMonitorSnapshot] = [:]
            for ch in channels {
                let (cL, cR) = ch.getLevels()
                let dbL = cL > 1e-8 ? 20*log10(Double(cL)) : -96.0
                let dbR = cR > 1e-8 ? 20*log10(Double(cR)) : -96.0
                vu[ch.id] = (dbL, dbR)
                
                var snap = ChannelMonitorSnapshot(id: ch.id, name: ch.name, type: ch.type)
                snap.sourceDisplayName = ch.sourceDisplayName
                snap.isLive = ch.isLive.load() == 1
                snap.isPFL = ch.isPFL.load() == 1
                snap.volume = ch.volume.load()
                snap.isVoiceIsolationEnabled = ch.isVoiceIsolationEnabled
                snap.isKaraokeEnabled = ch.isKaraoke.load() == 1
                snap.inputDbL = Float(dbL)
                snap.inputDbR = Float(dbR)
                snap.qReady = cL > 1e-8 || cR > 1e-8
                snap.qSamples = snap.qReady ? 1 : 0
                monitors[ch.id] = snap
            }
            
            let finalVU = vu; let finalMonitors = monitors
            Task { @MainActor in
                let store = self.vuStore
                store.masterVULeft = mL > 1e-8 ? 20*log10(Double(mL)) : -96.0
                store.masterVURight = mR > 1e-8 ? 20*log10(Double(mR)) : -96.0
                store.pflVULeft = pL > 1e-8 ? 20*log10(Double(pL)) : -96.0
                store.pflVURight = pR > 1e-8 ? 20*log10(Double(pR)) : -96.0
                store.channelVULevels = finalVU
                store.channelMonitor = finalMonitors
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
    public func scanDevices() {
        // GCD no participa en la inferencia de actor isolation de Swift 6:
        // resuelve el error "Main actor-isolated ... cannot be called from outside of the actor"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var manager = AudioDeviceManager()
            manager.scanDevices()
            let inputs = manager.inputDevices
            let outputs = manager.outputDevices
            DispatchQueue.main.async { [weak self] in
                self?.inputDevices = inputs
                self?.outputDevices = outputs
            }
        }
    }
    public func setMasterVolume(_ v: Double) { volumeStudio = v; core.masterMixer.outputVolume = Float(v); if isMonitoringSynced { setPFLVolume(v) } }
    public func setPFLVolume(_ v: Double) { volumePhones = v; core.pflMixer.outputVolume = Float(v) }
    public func setMasterPan(_ p: Double) { masterPan = p; core.atomicMasterPan.store(Float(p)); if isMonitoringSynced { setPFLPan(p) } }
    public func setPFLPan(_ p: Double) { pflPan = p; core.atomicPflPan.store(Float(p)) }
    public func setSource(_ name: String, for id: UUID, type: ChannelType, voiceIsolation: Bool = false) -> AudioSourceID {
        let ch = core.registry.getChannel(id)
        
        // 1. Detener cualquier captura activa (tanto de hardware como de aplicación)
        // para evitar superposición de datos (cortes o desincronización en el ring buffer).
        HardwareCaptureManager.shared.stopCapture(for: id)
        Task { await AppCaptureManager.shared.stopCapture(for: id) }
        
        // 2. Limpiar el búfer para descartar datos residuales del dispositivo anterior.
        ch?.queue.clear()
        ch?.sourceDisplayName = name
        
        if name == "Ninguna" {
            return .none
        }
        
        if type == .mic {
            if let d = self.inputDevices.first(where: { $0.name == name }) {
                HardwareCaptureManager.shared.startCapture(for: id, device: d, voiceIsolation: voiceIsolation)
            }
        } else if type == .hardware || type == .app {
            if let d = self.inputDevices.first(where: { $0.name == name }) {
                HardwareCaptureManager.shared.startCapture(for: id, device: d, voiceIsolation: voiceIsolation)
            } else {
                Task { await AppCaptureManager.shared.startCapture(for: id, appName: name) }
            }
        }
        return .none
    }
    // [BUG-08] PreGain real: se aplica vía vDSP en el render thread, soporta 0.0–4.0x (hasta +12dB).
    public func setPreGain(_ v: Double, for id: UUID) { if let ch = core.registry.getChannel(id) { ch.atomicPreGain.store(Float(v)) } }
    
    // [BUG-09] Addresses correctas del kAudioUnitSubType_DynamicsProcessor de Apple:
    // 0=Threshold, 1=HeadRoom, 2=ExpansionRatio, 3=ExpansionThreshold, 4=AttackTime, 5=ReleaseTime
    public func setGateThreshold(_ v: Double, for id: UUID) {
        if let ch = core.registry.getChannel(id), let tree = ch.dynamicsNode.auAudioUnit.parameterTree {
            ch.atomicGateThreshold.store(Float(v))
            
            // [LATENCIA CERO] Si el Gate está apagado (<= -95dB) y el Limiter también (>= 0dB),
            // hacemos BYPASS total del nodo para eliminar su delay de Lookahead de CoreAudio.
            let isGateOff = v <= -95.0
            let isLimitOff = ch.atomicLimitThreshold.load() >= 0.0
            ch.dynamicsNode.bypass = (isGateOff && isLimitOff && !ch.isVoiceIsolationEnabled)
            
            tree.parameter(withAddress: 3)?.value = Float(v)   // ExpansionThreshold (Gate)
            tree.parameter(withAddress: 2)?.value = 50.0       // ExpansionRatio (gate fuerte)
        }
    }
    
    public func setLimitThreshold(_ v: Double, for id: UUID) {
        if let ch = core.registry.getChannel(id), let tree = ch.dynamicsNode.auAudioUnit.parameterTree {
            ch.atomicLimitThreshold.store(Float(v))
            
            let isGateOff = ch.atomicGateThreshold.load() <= -95.0
            let isLimitOff = v >= 0.0
            ch.dynamicsNode.bypass = (isGateOff && isLimitOff && !ch.isVoiceIsolationEnabled)
            
            tree.parameter(withAddress: 0)?.value = Float(v)   // Threshold (Limiter)
            tree.parameter(withAddress: 1)?.value = 3.0        // HeadRoom (3 dB estándar)
            tree.parameter(withAddress: 4)?.value = 0.001      // AttackTime (rápido)
        }
    }
    
    public func setVoiceIsolation(_ enabled: Bool, for id: UUID) {
        if let ch = core.registry.getChannel(id) {
            ch.isVoiceIsolationEnabled = enabled
            
            // Decidir bypass inteligentemente según el estado de todos los filtros de dinámica
            let isGateOff = ch.atomicGateThreshold.load() <= -95.0
            let isLimitOff = ch.atomicLimitThreshold.load() >= 0.0
            ch.dynamicsNode.bypass = (isGateOff && isLimitOff && !enabled)
            
            // [DSP] Simular Voice Isolation usando un Noise Gate agresivo
            if let tree = ch.dynamicsNode.auAudioUnit.parameterTree {
                if enabled {
                    tree.parameter(withAddress: 3)?.value = -35.0  // Corta todo lo menor a -35dB
                    tree.parameter(withAddress: 2)?.value = 50.0   // Ratio de corte extremo
                } else {
                    tree.parameter(withAddress: 3)?.value = -120.0 // Inaudible
                    tree.parameter(withAddress: 2)?.value = 1.0    // Bypass simulado
                }
            }
        }
    }
    public func applyOutputDevice(_ name: String, for bus: AudioOutputBus) {
        if name == "Ninguna" || name.isEmpty {
            switch bus {
            case .streaming:
                selectedOutputStreamingUID = ""
                core.streamingOutput.stop()
                print("🛑 [AudioEngine] Salida de STREAMING desactivada (Ninguna)")
            case .pfl:
                selectedOutputPFLUID = ""
                core.pflOutput.stop()
                print("🛑 [AudioEngine] Salida de PFL desactivada (Ninguna)")
            case .master:
                selectedOutputGeneralUID = ""
                core.masterOutput.stop()
                print("🛑 [AudioEngine] Salida de GENERAL desactivada (Ninguna)")
            }
            return
        }
        
        guard let dev = outputDevices.first(where: { $0.name == name }) else { return }
        switch bus {
        case .streaming:
            if core.streamingOutput.start(deviceID: dev.id) {
                selectedOutputStreamingUID = dev.uid
                print("🚀 [AudioEngine] Salida de STREAMING activada: \(name)")
            } else {
                selectedOutputStreamingUID = "" // Forzar a "Ninguna" si falló
                print("⚠️ [AudioEngine] Falló inicialización de STREAMING para \(name). Revirtiendo a Ninguna.")
                // Notify the UI visually through persistence reset
                NotificationCenter.default.post(name: Notification.Name("RevertStreamingOutput"), object: nil)
            }
        case .pfl:
            if core.pflOutput.start(deviceID: dev.id) {
                selectedOutputPFLUID = dev.uid
                print("🚀 [AudioEngine] Salida de PFL activada: \(name)")
            } else {
                selectedOutputPFLUID = ""
                print("⚠️ [AudioEngine] Falló inicialización de PFL para \(name). Revirtiendo a Ninguna.")
                NotificationCenter.default.post(name: Notification.Name("RevertPFLOutput"), object: nil)
            }
        case .master:
            if core.masterOutput.start(deviceID: dev.id) {
                selectedOutputGeneralUID = dev.uid
                print("🚀 [AudioEngine] Salida de GENERAL activada: \(name)")
            } else {
                selectedOutputGeneralUID = ""
                print("⚠️ [AudioEngine] Falló inicialización de GENERAL para \(name). Revirtiendo a Ninguna.")
                NotificationCenter.default.post(name: Notification.Name("RevertGeneralOutput"), object: nil)
            }
        }
    }
    
    // MARK: - Multi-Destination Output Management
    
    /// Añade un slot extra vacío (“Ninguna”) para que el usuario elija un dispositivo.
    public func addExtraOutputSlot(for bus: AudioOutputBus) {
        switch bus {
        case .master:
            guard extraGeneralOutputs.count < AudioEngineCore.maxExtraOutputs else { return }
            extraGeneralOutputs.append((uid: "", name: "Ninguna"))
        case .pfl:
            guard extraPFLOutputs.count < AudioEngineCore.maxExtraOutputs else { return }
            extraPFLOutputs.append((uid: "", name: "Ninguna"))
        case .streaming: break
        }
    }
    
    /// Actualiza el dispositivo de un slot extra (cuando el usuario cambia el Picker).
    public func updateExtraOutput(at index: Int, name: String, for bus: AudioOutputBus) {
        switch bus {
        case .master:
            guard index < extraGeneralOutputs.count else { return }
            if name == "Ninguna" || name.isEmpty {
                extraGeneralOutputs[index] = (uid: "", name: "Ninguna")
            } else if let dev = outputDevices.first(where: { $0.name == name }) {
                extraGeneralOutputs[index] = (uid: dev.uid, name: dev.name)
            }
            rebuildExtraSessions(for: .master)
        case .pfl:
            guard index < extraPFLOutputs.count else { return }
            if name == "Ninguna" || name.isEmpty {
                extraPFLOutputs[index] = (uid: "", name: "Ninguna")
            } else if let dev = outputDevices.first(where: { $0.name == name }) {
                extraPFLOutputs[index] = (uid: dev.uid, name: dev.name)
            }
            rebuildExtraSessions(for: .pfl)
        case .streaming: break
        }
    }
    
    /// Elimina un slot extra y reconstruye las sesiones activas.
    public func removeExtraOutput(at index: Int, for bus: AudioOutputBus) {
        switch bus {
        case .master:
            guard index < extraGeneralOutputs.count else { return }
            extraGeneralOutputs.remove(at: index)
            rebuildExtraSessions(for: .master)
        case .pfl:
            guard index < extraPFLOutputs.count else { return }
            extraPFLOutputs.remove(at: index)
            rebuildExtraSessions(for: .pfl)
        case .streaming: break
        }
    }
    
    /// Restaura las salidas extra desde persistencia. Llamado por ConsolePersistenceManager.
    public func restoreExtraOutputs(generalUIDs: [String], generalNames: [String],
                                     pflUIDs: [String], pflNames: [String]) {
        extraGeneralOutputs = zip(generalUIDs, generalNames).map { (uid: $0, name: $1) }
        extraPFLOutputs = zip(pflUIDs, pflNames).map { (uid: $0, name: $1) }
        rebuildExtraSessions(for: .master)
        rebuildExtraSessions(for: .pfl)
    }
    
    /// Reconstruye las sesiones AUHAL de salidas extra, compactando los slots activos
    /// sin huecos para que el tap los recorra de forma contigua y lock-free.
    private func rebuildExtraSessions(for bus: AudioOutputBus) {
        switch bus {
        case .master:
            // 1. Detener todos los slots
            for slot in core.extraMasterOutputs { slot.stop() }
            // 2. Iniciar sólo los que tienen dispositivo real, en orden compacto
            var activeIdx = 0
            for item in extraGeneralOutputs where !item.uid.isEmpty {
                if let dev = outputDevices.first(where: { $0.uid == item.uid }), activeIdx < AudioEngineCore.maxExtraOutputs {
                    core.extraMasterOutputs[activeIdx].start(deviceID: dev.id)
                    activeIdx += 1
                }
            }
            // 3. Actualizar el contador atómico que lee el tap en tiempo real
            core.atomicExtraMasterCount.store(activeIdx)
        case .pfl:
            for slot in core.extraPflOutputs { slot.stop() }
            var activeIdx = 0
            for item in extraPFLOutputs where !item.uid.isEmpty {
                if let dev = outputDevices.first(where: { $0.uid == item.uid }), activeIdx < AudioEngineCore.maxExtraOutputs {
                    core.extraPflOutputs[activeIdx].start(deviceID: dev.id)
                    activeIdx += 1
                }
            }
            core.atomicExtraPflCount.store(activeIdx)
        case .streaming: break
        }
    }
}

// MARK: - 6. REGISTRY & BUFFERS
final class ChannelRegistry: @unchecked Sendable {
    private struct Storage { var channels: [UUID: RenderChannel] = [:]; var order: [UUID] = [] }
    private let lock = OSAllocatedUnfairLock(initialState: Storage())
    func register(_ ch: RenderChannel) { lock.withLock { $0.channels[ch.id] = ch; $0.order.append(ch.id) } }
    func unregister(id: UUID) { lock.withLock { $0.channels.removeValue(forKey: id); $0.order.removeAll { $0 == id } } }
    func getChannel(_ id: UUID) -> RenderChannel? { lock.withLock { $0.channels[id] } }
    func snapshot() -> [RenderChannel] { lock.withLock { storage in storage.order.compactMap { storage.channels[$0] } } }
}

final class LockFreeRingBuffer: @unchecked Sendable {
    private let bufferL, bufferR: UnsafeMutablePointer<Float>; private let capacity: Int
    private let head = AtomicValue<Int>(0); private let tail = AtomicValue<Int>(0)
    private let enableCatchUp: Bool
    private let maxLatencyAtomic: AtomicValue<Int>
    private let targetLatencyAtomic: AtomicValue<Int>
    private let isBuffering = AtomicValue<Bool>(true)
    
    var targetLatency: Int { targetLatencyAtomic.load() }
    var maxLatency: Int { maxLatencyAtomic.load() }
    
    init(capacityFrames: Int, enableCatchUp: Bool = false, maxLatency: Int = 14400, targetLatency: Int = 2048) {
        self.capacity = capacityFrames
        self.enableCatchUp = enableCatchUp
        self.maxLatencyAtomic = AtomicValue<Int>(maxLatency)
        self.targetLatencyAtomic = AtomicValue<Int>(targetLatency)
        self.bufferL = .allocate(capacity: capacityFrames)
        self.bufferR = .allocate(capacity: capacityFrames)
        self.bufferL.initialize(repeating: 0, count: capacityFrames)
        self.bufferR.initialize(repeating: 0, count: capacityFrames)
    }
    
    func updateThresholds(target: Int, max: Int) {
        targetLatencyAtomic.store(target)
        maxLatencyAtomic.store(max)
        resetToTarget()
    }
    
    func clear() { head.store(0); tail.store(0); isBuffering.store(true); vDSP_vclr(bufferL, 1, vDSP_Length(capacity)); vDSP_vclr(bufferR, 1, vDSP_Length(capacity)) }
    
    func resetToTarget() {
        let h = head.load()
        let t = (h - targetLatency + capacity) % capacity
        tail.store(t)
    }
    
    func enqueue(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        let h = head.load(); let t = tail.load(); let used = (h - t + capacity) % capacity
        if (capacity - used - 1) < frames { return }
        let f1 = min(frames, capacity - h); memcpy(bufferL.advanced(by: h), left, f1 * 4); memcpy(bufferR.advanced(by: h), right, f1 * 4)
        if frames > f1 { let f2 = frames - f1; memcpy(bufferL, left.advanced(by: f1), f2 * 4); memcpy(bufferR, right.advanced(by: f1), f2 * 4) }
        head.store((h + frames) % capacity)
    }
    
    func dequeue(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let h = head.load(); var t = tail.load(); var used = (h - t + capacity) % capacity
        
        // CATCH-UP DE LATENCIA (OVERFLOW)
        if enableCatchUp && used > maxLatency {
            let framesToDrop = used - targetLatency
            t = (t + framesToDrop) % capacity
            tail.store(t)
            used = targetLatency
        }
        
        // [DSP-SMOOTH] LECTURA PARCIAL RESILIENTE
        let framesToRead = min(frames, used)
        if framesToRead > 0 {
            let f1 = min(framesToRead, capacity - t)
            memcpy(left, bufferL.advanced(by: t), f1 * 4)
            memcpy(right, bufferR.advanced(by: t), f1 * 4)
            if framesToRead > f1 {
                let f2 = framesToRead - f1
                memcpy(left.advanced(by: f1), bufferL, f2 * 4)
                memcpy(right.advanced(by: f1), bufferR, f2 * 4)
            }
            t = (t + framesToRead) % capacity
            tail.store(t)
        }
        
        // Rellenar el espacio sobrante con silencio si hubo underflow leve
        if framesToRead < frames {
            vDSP_vclr(left.advanced(by: framesToRead), 1, vDSP_Length(frames - framesToRead))
            vDSP_vclr(right.advanced(by: framesToRead), 1, vDSP_Length(frames - framesToRead))
        }
    }
    func availableFrames() -> Int { let h = head.load(); let t = tail.load(); return (h - t + capacity) % capacity }
}

// [Swift 6] Función global sin aislamiento de actor: puede llamarse desde Task.detached
// sin violar las reglas de concurrencia. RadioAudioEngine.scanDevices() delega aquí.
func AudioEngine_scanDevicesOffMain() -> (inputs: [AudioDevice], outputs: [AudioDevice]) {
    var manager = AudioDeviceManager()
    manager.scanDevices()
    return (manager.inputDevices, manager.outputDevices)
}

struct AudioDeviceManager {
    var inputDevices: [AudioDevice] = []; var outputDevices: [AudioDevice] = []
    mutating func scanDevices() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0; AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        let count = Int(size) / 4; var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        inputDevices.removeAll(); outputDevices.removeAll()
        
        print("🔍 [Hardware Scan] --- DETECTADOS EN COREAUDIO ---")
        for id in ids {
            let n = getDN(id); let u = getDU(id)
            let isInput = getDir(id, isInput: true)
            let isOutput = getDir(id, isInput: false)
            
            if isInput {
                let range = getBufferRange(id, isInput: true)
                // [FIX-OVERLOAD] Solo ajustar el búfer en hardware FÍSICO real.
                // Los drivers virtuales (HALC_ProxyIOContext: CASTER, Teams, Radio Mixer, etc.)
                // reportan range.min <= 16 pero no pueden sostener ciclos a esa velocidad,
                // causando IOWorkLoop overloads. Se filtra por TransportType.
                if range.min > 0 && range.min <= 16 && isRealHardwareDevice(id) {
                    setBufferSize(id, isInput: true, size: 16)
                }
                
                let fmt = getFormat(id, isInput: true)
                let buf = getBufferSize(id, isInput: true)
                let ms = fmt.sampleRate > 0 ? (Double(buf) / fmt.sampleRate) * 1000.0 : 0.0
                let minMs = fmt.sampleRate > 0 ? (range.min / fmt.sampleRate) * 1000.0 : 0.0
                let maxMs = fmt.sampleRate > 0 ? (range.max / fmt.sampleRate) * 1000.0 : 0.0
                
                print("   🎙️ [ENTRADA] Name: \(n) | Rate: \(fmt.sampleRate)Hz | Channels: \(fmt.channels)ch")
                // Mantenimiento posterior: Muestra el tamaño de búfer actual y límites físicos de entradas
                print("      ├─ Búfer Actual: \(buf) frames (~\(String(format: "%.1f", ms))ms)")
                print("      └─ Límites Físicos del Chip: \(Int(range.min)) frames (~\(String(format: "%.2f", minMs))ms) a \(Int(range.max)) frames (~\(String(format: "%.1f", maxMs))ms)")
                
                inputDevices.append(AudioDevice(id: id, uid: u, name: n, isInput: true, isOutput: false))
            }
            if isOutput {
                let fmt = getFormat(id, isInput: false)
                let buf = getBufferSize(id, isInput: false)
                let ms = fmt.sampleRate > 0 ? (Double(buf) / fmt.sampleRate) * 1000.0 : 0.0
                let range = getBufferRange(id, isInput: false)
                let minMs = fmt.sampleRate > 0 ? (range.min / fmt.sampleRate) * 1000.0 : 0.0
                let maxMs = fmt.sampleRate > 0 ? (range.max / fmt.sampleRate) * 1000.0 : 0.0
                
                print("   🎧 [SALIDA]  Name: \(n) | Rate: \(fmt.sampleRate)Hz | Channels: \(fmt.channels)ch")
                // Mantenimiento posterior: Muestra el tamaño de búfer actual y límites físicos de salidas
                print("      ├─ Búfer Actual: \(buf) frames (~\(String(format: "%.1f", ms))ms)")
                print("      └─ Límites Físicos del Chip: \(Int(range.min)) frames (~\(String(format: "%.2f", minMs))ms) a \(Int(range.max)) frames (~\(String(format: "%.1f", maxMs))ms)")
                
                outputDevices.append(AudioDevice(id: id, uid: u, name: n, isInput: false, isOutput: true))
            }
        }
        print("🔍 [Hardware Scan] ---------------------------------")
    }
    private func setBufferSize(_ id: AudioDeviceID, isInput: Bool, size: UInt32) {
        var bufferSize = size
        var addrGlobal = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(id, &addrGlobal) {
            AudioObjectSetPropertyData(id, &addrGlobal, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bufferSize)
        }
        var addrDir = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(id, &addrDir) {
            AudioObjectSetPropertyData(id, &addrDir, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bufferSize)
        }
    }
    private func getDN(_ id: AudioDeviceID) -> String { var n: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size); var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0); AudioObjectGetPropertyData(id, &a, 0, nil, &s, &n); return n?.takeRetainedValue() as String? ?? "Unknown" }
    private func getDU(_ id: AudioDeviceID) -> String { var u: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size); var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0); AudioObjectGetPropertyData(id, &a, 0, nil, &s, &u); return u?.takeRetainedValue() as String? ?? "" }
    private func getDir(_ id: AudioDeviceID, isInput: Bool) -> Bool { var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: 0); var s: UInt32 = 0; AudioObjectGetPropertyDataSize(id, &a, 0, nil, &s); return s > 0 }
    
    private func getFormat(_ id: AudioDeviceID, isInput: Bool) -> (sampleRate: Double, channels: Int) {
        var asbd = AudioStreamBasicDescription()
        var s = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(id, &a, 0, nil, &s, &asbd)
        if status == noErr {
            return (asbd.mSampleRate, Int(asbd.mChannelsPerFrame))
        }
        return (0.0, 0)
    }
    
    private func getBufferSize(_ id: AudioDeviceID, isInput: Bool) -> UInt32 {
        var bufferSize: UInt32 = 0
        var s = UInt32(MemoryLayout<UInt32>.size)
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(id, &a, 0, nil, &s, &bufferSize)
        if status == noErr {
            return bufferSize
        }
        return 0
    }
    
    private func getBufferRange(_ id: AudioDeviceID, isInput: Bool) -> (min: Double, max: Double) {
        var range = AudioValueRange()
        var s = UInt32(MemoryLayout<AudioValueRange>.size)
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(id, &a, 0, nil, &s, &range)
        if status == noErr {
            return (range.mMinimum, range.mMaximum)
        }
        return (0.0, 0.0)
    }
    
    /// Devuelve true solo para dispositivos de hardware físico real (USB, Built-In, Thunderbolt,
    /// FireWire, Bluetooth, PCI, HDMI, DisplayPort). Excluye drivers virtuales (HALC_ProxyIOContext)
    /// como CASTER, Microsoft Teams, Radio Mixer, Audio AG Output, CADefaultDeviceAggregate, etc.
    private func isRealHardwareDevice(_ id: AudioDeviceID) -> Bool {
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transportType) == noErr else {
            return false
        }
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn,
             kAudioDeviceTransportTypeUSB,
             kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypePCI:
            return true
        default:
            // kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
            // kAudioDeviceTransportTypeUnknown → drivers proxy/virtuales → NO ajustar buffer
            return false
        }
    }
}

// MARK: - 6. MASTER RECORDER SYSTEM
enum RecordFormat: String, CaseIterable, Identifiable {
    case wav = "WAV (Lossless)"
    case m4a = "M4A (AAC 320kbps)"
    case mp3 = "MP3 (LAME 320kbps)"
    
    var id: String { self.rawValue }
    var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .m4a: return "m4a"
        case .mp3: return "mp3"
        }
    }
}

final class MasterRecorder: ObservableObject, @unchecked Sendable {
    static let shared = MasterRecorder()
    
    @Published var isRecording = false
    @Published var isConverting = false
    @Published var durationString = "00:00:00"
    @Published var recordURL: URL?
    
    private var audioFile: AVAudioFile?
    private let writeQueue = DispatchQueue(label: "com.radioag.recorder.writeQueue", qos: .userInitiated)
    private let recordingActive = AtomicValue<Bool>(false)
    private let totalFramesWritten = AtomicValue<Int64>(0)
    private var timer: Timer?
    private var startTime: Date?
    
    private var targetURL: URL?
    private var tempWavURL: URL?
    private var shouldConvertToMP3 = false
    
    private init() {}
    
    func startRecording(to url: URL, format: RecordFormat) throws {
        guard !isRecording else { return }
        
        var actualURL = url
        shouldConvertToMP3 = (format == .mp3)
        
        if shouldConvertToMP3 {
            // Si es MP3, grabamos en un archivo WAV temporal en la misma carpeta para codificarlo después
            let tempWav = url.deletingPathExtension().appendingPathExtension("wav")
            self.tempWavURL = tempWav
            self.targetURL = url
            actualURL = tempWav
        } else {
            self.tempWavURL = nil
            self.targetURL = nil
        }
        
        let settings: [String: Any]
        switch format {
        case .wav:
            settings = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        case .mp3:
            settings = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, // LAME requiere alineamiento estándar de 16 bits para analizar estéreo correctamente
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        case .m4a:
            settings = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 320000
            ]
        }
        
        audioFile = try AVAudioFile(forWriting: actualURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        
        recordURL = url
        totalFramesWritten.store(0)
        startTime = Date()
        recordingActive.store(true)
        
        DispatchQueue.main.async {
            self.isRecording = true
            self.isConverting = false
            self.durationString = "00:00:00"
            self.startTimer()
        }
    }
    
    func stopRecording() {
        guard recordingActive.load() else { return }
        recordingActive.store(false)
        stopTimer()
        
        writeQueue.sync {
            self.audioFile = nil
        }
        
        if shouldConvertToMP3, let tempWav = tempWavURL, let targetMp3 = targetURL {
            DispatchQueue.main.async {
                self.isConverting = true
                self.durationString = "CONVIRTIENDO..."
            }
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                self.convertWavToMp3(source: tempWav, destination: targetMp3) { success in
                    DispatchQueue.main.async {
                        self.isRecording = false
                        self.isConverting = false
                        self.tempWavURL = nil
                        self.targetURL = nil
                    }
                }
            }
        } else {
            DispatchQueue.main.async {
                self.isRecording = false
            }
        }
    }
    
    func write(buffer: AVAudioPCMBuffer) {
        guard recordingActive.load() else { return }
        
        // Copiar el buffer de forma segura e instantánea para evitar race conditions
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else { return }
        copy.frameLength = buffer.frameLength
        if let srcL = buffer.floatChannelData?[0], let dstL = copy.floatChannelData?[0] {
            memcpy(dstL, srcL, Int(buffer.frameLength) * 4)
        }
        if buffer.format.channelCount > 1, let srcR = buffer.floatChannelData?[1], let dstR = copy.floatChannelData?[1] {
            memcpy(dstR, srcR, Int(buffer.frameLength) * 4)
        }
        
        writeQueue.async { [weak self] in
            guard let self = self, self.recordingActive.load(), let file = self.audioFile else { return }
            do {
                try file.write(from: copy)
                let frames = Int64(copy.frameLength)
                let current = self.totalFramesWritten.load()
                self.totalFramesWritten.store(current + frames)
            } catch {
                print("❌ [Recorder] Error escribiendo buffer a disco: \(error.localizedDescription)")
            }
        }
    }
    
    private func convertWavToMp3(source: URL, destination: URL, completion: @escaping (Bool) -> Void) {
        let process = Process()
        let lamePaths = [
            "/opt/homebrew/bin/lame",
            "/usr/local/bin/lame",
            "/usr/bin/lame"
        ]
        
        var selectedPath = "/opt/homebrew/bin/lame"
        for path in lamePaths {
            if FileManager.default.fileExists(atPath: path) {
                selectedPath = path
                break
            }
        }
        
        process.executableURL = URL(fileURLWithPath: selectedPath)
        process.arguments = ["-m", "s", "-b", "320", "-q", "0", "--silent", source.path, destination.path]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        process.terminationHandler = { proc in
            let success = proc.terminationStatus == 0
            try? FileManager.default.removeItem(at: source)
            completion(success)
        }
        
        do {
            try process.run()
        } catch {
            print("❌ [Recorder] Error ejecutando LAME: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: source)
            completion(false)
        }
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            let elapsed = Date().timeIntervalSince(start)
            let hrs = Int(elapsed) / 3600
            let mins = (Int(elapsed) % 3600) / 60
            let secs = Int(elapsed) % 60
            
            DispatchQueue.main.async {
                self.durationString = String(format: "%02d:%02d:%02d", hrs, mins, secs)
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}


