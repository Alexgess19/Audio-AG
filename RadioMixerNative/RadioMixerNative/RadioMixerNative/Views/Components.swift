import SwiftUI
import AppKit

/**
 * Components.swift — Componentes de UI Profesional para Audio AG
 *
 * ARQUITECTURA DE COMPONENTES:
 * Cada componente es autónomo y sin dependencia a singletons.
 * Los valores se reciben como @Binding o parámetros simples.
 *
 * OPTIMIZACIONES CLAVE:
 * - VUMeterView: Usa Canvas (GPU-acelerado) en lugar de ForEach de 20 rectángulos.
 *   Esto reduce la carga de SwiftUI de O(20×N_canales) vistas a O(N_canales) draws.
 * - Faders/Pan: Usan NSView nativo (FaderEventBridge/PanEventBridge) para
 *   captura de scroll y drag con latencia mínima, sin pasar por el hit-testing de SwiftUI.
 * - RangeSlider: Componente nativo para Gate/Limiter con dos knobs independientes.
 */

// MARK: - VerticalFader
// Fader vertical con estética de consola profesional.
// Soporta: scroll wheel (con shift para modo fino), drag, y doble-click para reset a 0.8 (nivel nominal).
struct VerticalFader: View {
    @Binding var value: Double
    let knobHeight: CGFloat = 35
    
    var body: some View {
        GeometryReader { geometry in
            let trackHeight = geometry.size.height - knobHeight
            let yOffset = CGFloat(1.0 - value) * trackHeight
            
            ZStack(alignment: .top) {
                Color.white.opacity(0.001) // Superficie invisible para captura de gestos

                // Track: Ranura central del fader
                Capsule()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: 6)
                    .padding(.vertical, knobHeight / 2)
                
                // Fill: Indicador de nivel actual (cyan translúcido)
                VStack {
                    Spacer(minLength: 0)
                    Capsule()
                        .fill(Color.cyan.opacity(0.3))
                        .frame(width: 6, height: CGFloat(value) * trackHeight)
                }
                .padding(.vertical, knobHeight / 2)
                
                // Knob: Cabezal metálico con gradiente y línea central
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(gradient: Gradient(colors: [Color.gray, Color(hex: "f0f0f0"), Color.gray]),
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 28, height: knobHeight)
                    .overlay(Rectangle().fill(Color.black.opacity(0.4)).frame(height: 1))
                    .offset(y: yOffset)
            }
            .overlay(FaderEventBridge(value: $value))
            .contentShape(Rectangle())
        }
    }
}

// MARK: - HorizontalPanSlider
// Control de panorama estéreo (-1.0 = izquierda, 0.0 = centro, 1.0 = derecha).
// Doble-click resetea al centro.
struct HorizontalPanSlider: View {
    @Binding var value: Double
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            VStack(spacing: 2) {
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black.opacity(0.3))
                        .frame(height: 4)
                    
                    // Marcador central (referencia visual de "centro")
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 1, height: 8)
                    
                    // Thumb del paneo — posición calculada sobre el ancho real
                    let xPos = (value + 1.0) / 2.0 * w
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 12, height: 12)
                        .shadow(radius: 1)
                        .position(x: xPos, y: 10) // 10 = mitad del frame height de 20
                    
                    PanEventBridge(value: $value)
                }
                .frame(width: w, height: 20)
                
                HStack {
                    Text("L").font(.system(size: 7, weight: .bold))
                    Spacer()
                    Text("R").font(.system(size: 7, weight: .bold))
                }
                .foregroundColor(.white.opacity(0.4))
                .frame(width: w)
            }
        }
        .frame(height: 30) // altura total fija: 20 (slider) + 2 (spacing) + 8 (etiquetas)
    }
}

// MARK: - VUMeterView (Canvas — GPU Acelerado)
// ANTES: ForEach(0..<20) creaba 20 rectángulos SwiftUI por medidor.
//        Con 20 canales × 2 (L/R) × 20 segmentos = 800 vistas actualizándose a 20Hz.
// AHORA: Canvas dibuja TODO en una sola pasada GPU. O(1) por medidor.
//        Esto es lo que usan Logic Pro y Ableton para sus meters.
struct VUMeterView: View {
    var value: Double   // dB RMS (típicamente -96 a 0)
    var width: CGFloat = 15
    
    // Convierte dB a valor lineal con curva perceptual logarítmica
    private var linearValue: Double {
        let minDb: Double = -60.0
        let maxDb: Double = 0.0
        if value < minDb { return 0.0 }
        if value > maxDb { return 1.0 }
        let normalized = (value - minDb) / (maxDb - minDb)
        // Curva perceptual: los humanos perciben volumen de forma logarítmica.
        // pow(1.7) comprime los valores bajos y expande los altos, imitando
        // el comportamiento de un vúmetro analógico VU (ballistic response).
        return pow(normalized, 1.7)
    }
    
    var body: some View {
        Canvas { context, size in
            let segments = 20
            let spacing: CGFloat = 2
            let segHeight = (size.height - CGFloat(segments - 1) * spacing) / CGFloat(segments)
            let activeSegments = Int(linearValue * Double(segments))
            
            for i in 0..<segments {
                // Dibujamos de abajo hacia arriba: segmento 0 = base (verde), segmento 19 = pico (rojo)
                let segIndex = segments - 1 - i
                let y = CGFloat(i) * (segHeight + spacing)
                let rect = CGRect(x: 0, y: y, width: size.width, height: segHeight)
                
                // Paleta de colores profesional (verde → naranja → rojo)
                let color: Color
                if segIndex > 15 { color = .red }
                else if segIndex > 12 { color = .orange }
                else { color = .green }
                
                // Segmentos activos: opacidad completa. Inactivos: tenue (LED apagado)
                let opacity: Double = segIndex < activeSegments ? 1.0 : 0.15
                
                context.fill(Path(roundedRect: rect, cornerRadius: 1),
                             with: .color(color.opacity(opacity)))
            }
        }
        .frame(width: width)
        .padding(2)
        .background(Color.black.opacity(0.8))
        .cornerRadius(2)
    }
}

// MARK: - Event Bridges (macOS Native — Bypass SwiftUI Hit Testing)
// Estos puentes NSView permiten capturar eventos de ratón y scroll directamente
// desde AppKit, evitando el overhead del sistema de gestos de SwiftUI.
// Esto es crítico para faders de audio donde cada milisegundo cuenta.

struct FaderEventBridge: NSViewRepresentable {
    @Binding var value: Double
    func makeNSView(context: Context) -> FaderNativeView {
        let view = FaderNativeView()
        view.onChanged = { self.value = $0 }
        return view
    }
    func updateNSView(_ nsView: FaderNativeView, context: Context) { nsView.currentValue = value }
}

class FaderNativeView: NSView {
    var onChanged: ((Double) -> Void)?
    var currentValue: Double = 0.0
    
    override func scrollWheel(with event: NSEvent) {
        // Natural Scrolling: Respeta la preferencia del sistema.
        // Shift: Modo fino (0.0004) para ajustes de precisión (±0.1 dB).
        let direction: Double = event.isDirectionInvertedFromDevice ? -1.0 : 1.0
        let sensitivity: Double = event.modifierFlags.contains(.shift) ? 0.0004 : 0.002
        let nv = min(max(0, currentValue + Double(event.scrollingDeltaY) * sensitivity * direction), 1.0)
        onChanged?(nv)
    }
    
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onChanged?(0.8) } // Doble-click: Reset a nivel nominal (-2 dB)
        else { update(with: event) }
    }
    
    override func mouseDragged(with event: NSEvent) { update(with: event) }
    
    private func update(with event: NSEvent) {
        guard frame.height > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        onChanged?(min(max(0, Double(p.y / frame.height)), 1.0))
    }
}

struct PanEventBridge: NSViewRepresentable {
    @Binding var value: Double
    func makeNSView(context: Context) -> PanNativeView {
        let view = PanNativeView()
        view.onChanged = { self.value = $0 }
        return view
    }
    func updateNSView(_ nsView: PanNativeView, context: Context) { nsView.currentValue = value }
}

class PanNativeView: NSView {
    var onChanged: ((Double) -> Void)?
    var currentValue: Double = 0.0
    
    override func scrollWheel(with event: NSEvent) {
        let direction: Double = event.isDirectionInvertedFromDevice ? -1.0 : 1.0
        let sensitivity: Double = event.modifierFlags.contains(.shift) ? 0.001 : 0.005
        let delta = Double(event.scrollingDeltaX + event.scrollingDeltaY)
        let nv = min(max(-1.0, currentValue + delta * sensitivity * direction), 1.0)
        onChanged?(nv)
    }
    
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onChanged?(0.0) } // Doble-click: Reset al centro
        else { update(with: event) }
    }
    
    override func mouseDragged(with event: NSEvent) { update(with: event) }
    
    private func update(with event: NSEvent) {
        guard frame.width > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        onChanged?(min(max(-1.0, Double(p.x / frame.width) * 2.0 - 1.0), 1.0))
    }
}

// MARK: - Generic Scroll Support
// Modificador genérico para capturar scroll wheel en cualquier vista SwiftUI.
// Usado por los sliders de EQ para soporte nativo de rueda.
struct ScrollWheelModifier: ViewModifier {
    let perform: (NSEvent) -> Void
    func body(content: Content) -> some View {
        content.overlay(GenericScrollHandler(perform: perform))
    }
}

struct GenericScrollHandler: NSViewRepresentable {
    let perform: (NSEvent) -> Void
    func makeNSView(context: Context) -> GenericScrollNSView {
        let view = GenericScrollNSView()
        view.onScroll = perform
        return view
    }
    func updateNSView(_ nsView: GenericScrollNSView, context: Context) {}
}

class GenericScrollNSView: NSView {
    var onScroll: ((NSEvent) -> Void)?
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
}

extension View {
    func onScrollWheel(perform: @escaping (NSEvent) -> Void) -> some View {
        self.modifier(ScrollWheelModifier(perform: perform))
    }
}

// MARK: - RangeSlider (Gate & Limiter)
// Control de rango dual para procesamiento de dinámica de micrófono.
// Knob naranja = Gate (umbral inferior), Knob cyan = Limiter (umbral superior).
// La zona coloreada entre ambos representa el rango dinámico útil.
struct RangeSlider: View {
    @Binding var lowerValue: Double // dB (-96 a 0) — Gate
    @Binding var upperValue: Double // dB (-96 a 0) — Limiter
    let range: ClosedRange<Double> = -96...0
    
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let lPos = CGFloat((lowerValue - range.lowerBound) / (range.upperBound - range.lowerBound)) * w
            let uPos = CGFloat((upperValue - range.lowerBound) / (range.upperBound - range.lowerBound)) * w
            
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.4))
                    .frame(height: 6)
                
                // Zona activa: gradiente naranja→cyan indica el rango útil
                Rectangle()
                    .fill(LinearGradient(colors: [.orange, .cyan], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, uPos - lPos), height: 6)
                    .offset(x: lPos)
                
                // Knob Gate
                Circle()
                    .fill(Color.orange)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 1))
                    .shadow(radius: 2)
                    .offset(x: lPos - 7)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let pct = Double(value.location.x / w)
                        let db = range.lowerBound + pct * (range.upperBound - range.lowerBound)
                        lowerValue = min(max(range.lowerBound, db), upperValue - 1)
                    })
                
                // Knob Limiter
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 1))
                    .shadow(radius: 2)
                    .offset(x: uPos - 7)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let pct = Double(value.location.x / w)
                        let db = range.lowerBound + pct * (range.upperBound - range.lowerBound)
                        upperValue = min(max(lowerValue + 1, db), range.upperBound)
                    })
            }
            .frame(height: 20)
            .position(x: w/2, y: geometry.size.height / 2)
        }
        .frame(height: 30)
    }
}

// MARK: - Control de Ganancia Popover
// Interfaz de ajuste de pre-amplificación para canales de micrófono.
// Rango: 0.0x (silencio) a 4.0x (+12 dB aproximadamente).
struct MicGainControl: View {
    @Binding var gain: Double
    
    var body: some View {
        VStack(spacing: 10) {
            Text("GANANCIA PRE-AMP")
                .font(.system(size: 9, weight: .black))
                .foregroundColor(.orange)
            
            HStack {
                Slider(value: $gain, in: 0...4)
                    .accentColor(.orange)
                Text(String(format: "%.1f x", gain))
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .frame(width: 40)
            }
            
            Text("Ajusta el nivel de entrada puro del micrófono")
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(12)
        .frame(width: 200)
        .background(Color(hex: "1a1a25"))
    }
}
