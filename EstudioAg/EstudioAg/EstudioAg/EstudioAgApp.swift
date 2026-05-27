import SwiftUI

/**
 * AudioAGApp.swift — Punto de Entrada
 *
 * ARQUITECTURA:
 * El engine y la persistencia se instancian AQUÍ (raíz del árbol de vistas)
 * y se inyectan como @EnvironmentObject a todos los hijos.
 *
 * Esto elimina el patrón `.shared` de las vistas, permitiendo:
 * - Testeo unitario con mocks
 * - Previews funcionales en Xcode
 * - Posibilidad futura de múltiples instancias (multi-mixer)
 *
 * Los Models (`ConsolePersistenceManager`, `AppCaptureManager`) mantienen
 * `.shared` internamente porque son singletons de infraestructura,
 * no de presentación. Las vistas NUNCA acceden directamente a ellos.
 */
@main
struct AudioAGApp: App {
    // MARK: - Fuentes de Verdad (Single Source of Truth)
    // Se crean UNA sola vez aquí y se propagan hacia abajo.
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            MainConsoleView()
                .environmentObject(container.engine)
                .environmentObject(container.persistence)
                .environmentObject(container.engine.vuStore)
        }
    }
}
