import SwiftUI
import Combine

/**
 * AppContainer.swift (Arquitectura v24.0 - Dependency Injection)
 * 
 * Este contenedor centraliza la creación y el ciclo de vida del motor de audio y la persistencia.
 * Elimina la dependencia de Singletons globales, permitiendo:
 * 1. Reinicio limpio del motor de audio.
 * 2. Pruebas unitarias aisladas.
 * 3. Previsualizaciones de SwiftUI sin efectos secundarios globales.
 */

@MainActor
class AppContainer: ObservableObject {
    let engine: RadioAudioEngine
    let persistence: ConsolePersistenceManager
    
    // Propagación de cambios: cuando engine o persistence cambian,
    // AppContainer notifica a SwiftUI para re-render.
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        self.engine = RadioAudioEngine()
        self.persistence = ConsolePersistenceManager(engine: self.engine)
        
        // Propagar objectWillChange de los hijos al contenedor
        engine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        
        persistence.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        
        print("🏗️ [AppContainer] Arquitectura inicializada correctamente.")
    }
}
