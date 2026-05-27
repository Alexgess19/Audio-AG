import Foundation
import Combine
import SwiftUI

/**
 * ConsolePersistenceManager.swift (Arquitectura Hardened v9 - Performance Optimized)
 * - DEBOUNCED PERSISTENCE: 5s delay to reduce I/O pressure on the audio engine.
 * - SILENT SAVE: Removed console logging during autosave to prevent thread blocking.
 * - HARDWARE DEBOUNCE: Orchestrates with RadioAudioEngine to prevent redundant rescans.
 */

@MainActor
class ConsolePersistenceManager: ObservableObject {
    @Published var state: ConsoleState
    private var cancellables = Set<AnyCancellable>()
    private let storageKey = "audio_ag_console_v8"
    
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    private let persistenceQueue = DispatchQueue(label: "audio.persistence.io", qos: .background)
    
    public init(engine: RadioAudioEngine) {
        let loaded = ConsolePersistenceManager.loadStatic(decoder: JSONDecoder(), key: "audio_ag_console_v8")
        self.state = loaded
        
        // Autosave reactivo con 5 segundos de margen para proteger el motor de audio
        $state
            .receive(on: persistenceQueue)
            .debounce(for: .seconds(5), scheduler: persistenceQueue)
            .sink { [weak self] (newState: ConsoleState) in
                self?.saveInternal(newState)
            }
            .store(in: &cancellables)
            
        // Recuperar rutas de salida si el Engine se reinicia (hot-swap de hardware)
        NotificationCenter.default.addObserver(forName: NSNotification.Name("EngineWillRecover"), object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                print("🔄 [Persistence] Re-aplicando salidas tras recuperación del Engine")
                engine.applyOutputDevice(self.state.selectedOutputStreamingName, for: .streaming)
                engine.applyOutputDevice(self.state.selectedOutputGeneralName, for: .master)
                engine.applyOutputDevice(self.state.selectedOutputPFLName, for: .pfl)
            }
        }
        
        // Manejadores de fallback si la inicialización de salidas de hardware falla
        NotificationCenter.default.addObserver(forName: NSNotification.Name("RevertStreamingOutput"), object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.state.selectedOutputStreamingName = "Ninguna" }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("RevertGeneralOutput"), object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.state.selectedOutputGeneralName = "Ninguna" }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("RevertPFLOutput"), object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.state.selectedOutputPFLName = "Ninguna" }
        }

        
        // Sincronizar UIDs del Engine al Estado persistente
        engine.$selectedOutputStreamingUID.sink { [weak self] uid in self?.state.selectedOutputStreamingUID = uid }.store(in: &cancellables)
        engine.$selectedOutputGeneralUID.sink { [weak self] uid in self?.state.selectedOutputGeneralUID = uid }.store(in: &cancellables)
        engine.$selectedOutputPFLUID.sink { [weak self] uid in self?.state.selectedOutputPFLUID = uid }.store(in: &cancellables)
        
        // Sincronizar salidas extra al estado persistente
        engine.$extraGeneralOutputs.sink { [weak self] outputs in
            self?.state.extraGeneralOutputUIDs = outputs.map { $0.uid }
            self?.state.extraGeneralOutputNames = outputs.map { $0.name }
        }.store(in: &cancellables)
        engine.$extraPFLOutputs.sink { [weak self] outputs in
            self?.state.extraPFLOutputUIDs = outputs.map { $0.uid }
            self?.state.extraPFLOutputNames = outputs.map { $0.name }
        }.store(in: &cancellables)
        
        // Sincronizar estado Master → Persistencia (reemplaza escrituras directas desde bindings)
        // El debounce de $state (5s) se encarga de guardar a disco automáticamente.
        engine.$volumeStudio.sink { [weak self] v in self?.state.volumeStudio = v }.store(in: &cancellables)
        engine.$volumePhones.sink { [weak self] v in self?.state.volumePhones = v }.store(in: &cancellables)
        engine.$masterPan.sink { [weak self] v in self?.state.masterPan = v }.store(in: &cancellables)
        engine.$pflPan.sink { [weak self] v in self?.state.pflPan = v }.store(in: &cancellables)
        engine.$isOnAir.sink { [weak self] v in self?.state.isOnAir = v }.store(in: &cancellables)
        engine.$isMonitoringSynced.sink { [weak self] v in self?.state.isMonitoringSynced = v }.store(in: &cancellables)
        
        startStartupPipeline(engine: engine)
    }
    
    private func startStartupPipeline(engine: RadioAudioEngine) {
        engine.$isEngineStarted
            .filter { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                print("🚀 [Persistence] Motor listo. Iniciando Pipeline de Restauración...")
                engine.scanDevices()
                self?.restoreEngineGraph(engine: engine)
                print("✅ [Persistence] Sesión restaurada correctamente")
            }
            .store(in: &cancellables)
    }
    
    private func restoreEngineGraph(engine: RadioAudioEngine) {
        let allChannels = state.appChannels + state.micChannels + state.hwChannels
        
        // SEGURIDAD BROADCAST: Nunca restaurar "AL AIRE" automáticamente.
        // El operador debe activar la emisión manualmente tras verificar el estado.
        engine.isOnAir = false
        
        engine.setMasterVolume(state.volumeStudio)
        engine.setPFLVolume(state.volumePhones)
        engine.setMasterPan(state.masterPan)
        engine.setPFLPan(state.pflPan)
        engine.isMonitoringSynced = state.isMonitoringSynced
        
        engine.applyOutputDevice(state.selectedOutputStreamingName, for: .streaming)
        engine.applyOutputDevice(state.selectedOutputGeneralName, for: .master)
        engine.applyOutputDevice(state.selectedOutputPFLName, for: .pfl)
        
        // Restaurar salidas extra multi-destino
        engine.restoreExtraOutputs(
            generalUIDs: state.extraGeneralOutputUIDs,
            generalNames: state.extraGeneralOutputNames,
            pflUIDs: state.extraPFLOutputUIDs,
            pflNames: state.extraPFLOutputNames
        )
        
        // OPTIMIZACIÓN: Restaurar canales de forma escalonada (1.2s entre cada uno).
        // Esto evita que 3+ AUHAL units se inicien simultáneamente, lo cual
        // causa el pico de CPU que genera "IOWorkLoop: skipping cycle due to overload".
        for (index, c) in allChannels.enumerated() {
            let delay = Double(index) * 1.2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // [BUG-11] Verificar en el registry (thread-safe) en lugar de vuStore.channelMonitor
                // para evitar la race condition con el timer de telemetría a 30Hz.
                if engine.core.registry.getChannel(c.id) == nil {
                    engine.createNewChannelNode(id: c.id, type: c.type, name: c.name)
                }
                
                // Parámetros DSP
                engine.setVolume(c.volume, for: c.id)
                engine.setPan(c.pan, for: c.id)
                engine.setPreGain(c.preGain, for: c.id)
                engine.setGateThreshold(c.gateThreshold, for: c.id)
                engine.setLimitThreshold(c.limitThreshold, for: c.id)
                // [BUG-07] Restaurar con el array de gains del modo correcto.
                engine.updateEQ(gains: c.currentEQGains, mode: c.eqMode, for: c.id)
                
                // Estado de canal (LIVE, PFL, efectos)
                engine.setLive(c.isLive, for: c.id)
                engine.setPFL(c.isPFL, for: c.id)
                engine.setKaraoke(c.isKaraokeEnabled, for: c.id)
                engine.setVoiceIsolation(c.isVoiceIsolationEnabled, for: c.id)
                
                // Restaurar fuente de audio con delay adicional
                if c.selectedSourceDisplayName != "Ninguna" && !c.selectedSourceDisplayName.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        _ = engine.setSource(c.selectedSourceDisplayName, for: c.id, type: c.type,
                                           voiceIsolation: c.isVoiceIsolationEnabled)
                    }
                }
            }
        }
    }
    
    public func addChannel(type: ChannelType, engine: RadioAudioEngine) {
        let name: String
        switch type {
        case .app: name = "APP \(state.appChannels.count + 1)"
        case .mic: name = "MIC \(state.micChannels.count + 1)"
        case .hardware: name = "HW \(state.hwChannels.count + 1)"
        }
        let newChannel = RadioChannel(type: type, name: name)
        switch type {
        case .mic: state.micChannels.append(newChannel)
        case .hardware: state.hwChannels.append(newChannel)
        case .app: state.appChannels.append(newChannel)
        }
        
        engine.createNewChannelNode(id: newChannel.id, type: newChannel.type, name: newChannel.name)
    }
    
    public func deleteChannel(id: UUID, type: ChannelType, engine: RadioAudioEngine) {
        switch type {
        case .mic: state.micChannels.removeAll { $0.id == id }
        case .hardware: state.hwChannels.removeAll { $0.id == id }
        case .app: state.appChannels.removeAll { $0.id == id }
        }
        engine.deleteChannelNode(for: id)
    }
    
    private static func loadStatic(decoder: JSONDecoder, key: String) -> ConsoleState {
        if let data = UserDefaults.standard.data(forKey: key),
           let loaded = try? decoder.decode(ConsoleState.self, from: data) {
            print("📥 [Persistence] Estado cargado de UserDefaults (\(key))")
            return loaded
        }
        return ConsoleState()
    }
    
    private func saveInternal(_ newState: ConsoleState) {
        do {
            let data = try encoder.encode(newState)
            UserDefaults.standard.set(data, forKey: storageKey)
            // Save silencioso para no interrumpir el motor de audio
        } catch {
            print("❌ [Persistence] Error al guardar: \(error)")
        }
    }
    
    func forceSave() {
        saveInternal(state)
    }
}
