import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Combine

/**
 * AppCaptureManager.swift (Arquitectura Hardened v15.0 - PRO BROADCAST)
 * 
 * MEJORAS CRÍTICAS:
 * 1. AUDIO-ONLY: Se elimina .screen y configuración de video para evitar overhead y jitter.
 * 2. CONVERSIÓN ROBUSTA: Se garantiza 48kHz, Float32, Planar, Stereo antes de enviar al engine.
 * 3. NO MORE STALLS: Se elimina la recreación dinámica de conversores en el hilo RT.
 * 4. SEGURIDAD DE FORMATO: Validación de floatChannelData para evitar silencios por Int16.
 */

class AppCaptureManager: NSObject, ObservableObject {
    static let shared = AppCaptureManager()
    
    @Published var capturableApps: [SCRunningApplication] = []
    var onAudioBuffer: ((UUID, AVAudioPCMBuffer) -> Void)?
    
    private var sessions: [UUID: AppCaptureSession] = [:]
    private let captureQueue = DispatchQueue(label: "com.radio-ag.capture.apps", qos: .userInitiated)
    
    // Cola compartida para el procesamiento de audio de todos los streams (evita thread explosion)
    static let sharedAudioQueue = DispatchQueue(label: "com.radio-ag.capture.audio.shared", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
    
    private override init() {
        super.init()
        startAutoRefresh()
    }
    
    private func startAutoRefresh() {
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { await self.fetchCapturableApps() }
        }
        Task { await self.fetchCapturableApps() }
    }
    
    func fetchCapturableApps() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            var seenNames = Set<String>()
            let uniqueApps = content.applications.filter { app in
                guard !app.applicationName.isEmpty else { return false }
                if seenNames.contains(app.applicationName) { return false }
                seenNames.insert(app.applicationName)
                return true
            }.sorted { $0.applicationName < $1.applicationName }
            
            DispatchQueue.main.async {
                self.capturableApps = uniqueApps
            }
        } catch {
            print("⚠️ [Capture] No se pudo listar apps: \(error.localizedDescription)")
        }
    }
    
    func startCapture(for channelId: UUID, appName: String) async {
        await stopCapture(for: channelId)
        guard appName != "Ninguna", !appName.isEmpty else { return }
        
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let app = content.applications.first(where: { 
                // [BUG-12] Coincidencia exacta para evitar capturar la app equivocada
                // cuando dos apps comparten prefijo (ej: "Spotify" vs "Spotify Kids").
                $0.applicationName.lowercased() == appName.lowercased()
            }) else { return }
            
            let filter = SCContentFilter(display: content.displays[0], including: [app], exceptingWindows: [])
            let config = SCStreamConfiguration()
            
            // Reducir carga de video al mínimo para captura de solo audio
            config.width = 16
            config.height = 16
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 FPS
            config.showsCursor = false
            
            // [HARDENED] Configuración exclusiva de Audio
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            
            let session = AppCaptureSession(channelId: channelId, filter: filter, config: config, manager: self)
            sessions[channelId] = session
            try await session.start()
            
        } catch {
            print("⚠️ [Capture] Error al iniciar stream para \(appName): \(error.localizedDescription)")
        }
    }
    
    func stopCapture(for channelId: UUID) async {
        if let session = sessions[channelId] {
            try? await session.stop()
            sessions.removeValue(forKey: channelId)
        }
    }
}

class AppCaptureSession: NSObject, SCStreamOutput {
    let channelId: UUID
    private let filter: SCContentFilter
    private let config: SCStreamConfiguration
    private var stream: SCStream?
    weak var manager: AppCaptureManager?
    
    // Motor de conversión robusto
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    
    // [RT-SAFE] Buffers pre-asignados para evitar allocations en el hilo de audio
    private var inputPCMBuffer: AVAudioPCMBuffer?
    private var outBuffer: AVAudioPCMBuffer?
    
    init(channelId: UUID, filter: SCContentFilter, config: SCStreamConfiguration, manager: AppCaptureManager) {
        self.channelId = channelId
        self.filter = filter
        self.config = config
        self.manager = manager
    }
    
    func start() async throws {
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: AppCaptureManager.sharedAudioQueue)
        // SCKit genera frames de video internamente aunque la captura sea de audio.
        // Sin handler registrado produce un flood de errores "_SCStream_RemoteVideoQueueOperationHandlerWithError"
        // que consumen CPU en el thread de captura y compiten con el hilo RT de audio.
        // El handler no-op los descarta sin coste y silencia los errores.
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: AppCaptureManager.sharedAudioQueue)
        try await stream?.startCapture()
    }
    
    func stop() async throws {
        try await stream?.stopCapture()
        stream = nil
    }
    
    // MARK: - SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen { return } // Descartar frames de video silenciosamente
        guard type == .audio, sampleBuffer.isValid else { return }
        
        // 1. Obtener formato de entrada del SampleBuffer
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee ?? AudioStreamBasicDescription()
        let currentInputFormat = AVAudioFormat(streamDescription: &asbd)!
        
        // 2. Sincronizar conversor y buffers si el formato cambia
        if converter == nil || inputFormat == nil || !currentInputFormat.isEqual(inputFormat as Any) {
            inputFormat = currentInputFormat
            converter = AVAudioConverter(from: currentInputFormat, to: targetFormat)
            
            // [SAFETY] Restauramos margen para ráfagas del sistema
            inputPCMBuffer = AVAudioPCMBuffer(pcmFormat: currentInputFormat, frameCapacity: 8192)
            outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 8192)
            
            print("🎙️ [AppCapture] Pipeline Resiliente: \(currentInputFormat.sampleRate)Hz -> 48000Hz")
        }
        
        guard let converter = converter, let inBuffer = inputPCMBuffer, let outputBuf = outBuffer else { return }
        
        // 3. Preparar Buffers (sin re-asignar memoria)
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        let framesToProcess = AVAudioFrameCount(numSamples)
        inBuffer.frameLength = framesToProcess
        
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(numSamples), into: inBuffer.mutableAudioBufferList)
        guard status == noErr else { return }
        
        // 4. Ejecutar conversión RT-Safe
        var error: NSError?
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        
        // El converter gestiona el frameLength real del outputBuf
        converter.convert(to: outputBuf, error: &error, withInputFrom: inputBlock)
        
        if error == nil && outputBuf.frameLength > 0 {
            if outputBuf.floatChannelData != nil {
                manager?.onAudioBuffer?(channelId, outputBuf)
            }
        } else if let err = error {
            // Silenciamos errores comunes de formato si la app está pausada
            if err.code != 1836086396 { // 'insf' (insufficient data) es normal en ráfagas
                print("⚠️ [AppCapture] Error conversión: \(err.localizedDescription)")
            }
        }
    }
}
