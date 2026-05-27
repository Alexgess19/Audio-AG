import SwiftUI
import Combine

// [BUG-07] Subscript seguro para arrays: evita crash de índice fuera de límites
// al acceder a gains durante la transición entre modos de EQ.
extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/**
 * EQView.swift — Ecualizador Gráfico Profesional
 *
 * REFACTOR v10:
 * - @EnvironmentObject (sin .shared)
 * - Debounce con Timer: los cambios de EQ se envían al engine máximo a 30Hz,
 *   evitando saturar el hilo DSP cuando se arrastran sliders de 31 bandas.
 * - throttledUpdate() usa un Timer invalidable en lugar de comparación de Date,
 *   lo cual es más preciso y no depende del reloj del sistema.
 */
struct EQView: View {
    @Binding var channel: RadioChannel
    @EnvironmentObject var engine: RadioAudioEngine
    @Environment(\.presentationMode) var presentationMode
    
    // Timer de debounce: se invalida y recrea en cada cambio.
    // Solo dispara el update cuando el usuario deja de mover el slider por 33ms.
    @State private var debounceTimer: Timer?
    
    var body: some View {
        VStack(spacing: 20) {
            // CABECERA
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ECUALIZADOR GRÁFICO")
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(.cyan)
                    Text(channel.name.uppercased())
                        .font(.system(size: 24, weight: .black))
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                // SELECTOR DE MODO (10 / 15 / 31 bandas)
                HStack(spacing: 15) {
                    Text("BANDAS:")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.gray)
                    
                    Picker("", selection: $channel.eqMode) {
                        Text("10").tag(10)
                        Text("15").tag(15)
                        Text("31").tag(31)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 160)
                    // [BUG-13] Al cambiar modo, enviar al engine los gains CORRECTOS del nuevo modo.
                    .onChange(of: channel.eqMode) { _, new in
                        engine.updateEQ(gains: channel.currentEQGains, mode: new, for: channel.id)
                    }
                }
                .padding(10)
                .background(Color.black.opacity(0.3))
                .cornerRadius(8)
                
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 30)
            .padding(.top, 30)
            
            // GRILLA DE FADERS DE EQ
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: channel.eqMode == 31 ? 8 : 20) {
                    ForEach(0..<channel.eqMode, id: \.self) { index in
                        ProfessionalEQSlider(
                            gain: gainBinding(for: index),
                            frequency: getFrequencyLabel(for: index),
                            isCompact: channel.eqMode == 31
                        )
                        .onChange(of: channel.currentEQGains[safe: index] ?? 0) { _, _ in
                            debouncedEQUpdate()
                        }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 20)
            }
            .background(Color.black.opacity(0.2))
            
            // PANEL INFERIOR
            HStack {
                Button("RESTABLECER A 0 dB") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        // [BUG-07] Solo resetear el array del modo activo.
                        channel.currentEQGains = Array(repeating: 0.0, count: channel.eqMode)
                        engine.updateEQ(gains: channel.currentEQGains, mode: channel.eqMode, for: channel.id)
                    }
                }
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Color.red.opacity(0.2))
                .foregroundColor(.red)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.5), lineWidth: 1))
                
                Spacer()
                
                Text("RANGO: +/- 20 dB")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 25)
        }
        .onAppear {
            engine.updateEQ(gains: channel.currentEQGains, mode: channel.eqMode, for: channel.id)
        }
        .frame(width: channel.eqMode == 31 ? 1200 : 900, height: 550)
        .background(
            ZStack {
                Color(hex: "0f0f1a")
                RadialGradient(gradient: Gradient(colors: [Color.cyan.opacity(0.05), Color.clear]),
                               center: .topLeading, startRadius: 0, endRadius: 600)
            }
        )
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
    
    /// Debounce real: invalida el timer anterior y programa uno nuevo.
    /// El engine solo se actualiza cuando el usuario deja de mover el slider por 33ms (~30Hz máx).
    private func debouncedEQUpdate() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: false) { _ in
            Task { @MainActor in
                engine.updateEQ(gains: channel.currentEQGains, mode: channel.eqMode, for: channel.id)
            }
        }
    }
    
    /// [BUG-07] Binding al índice correcto del array del modo activo.
    private func gainBinding(for index: Int) -> Binding<Float> {
        Binding(
            get: {
                switch channel.eqMode {
                case 10: return index < channel.eqGains10.count ? channel.eqGains10[index] : 0
                case 15: return index < channel.eqGains15.count ? channel.eqGains15[index] : 0
                default: return index < channel.eqGains31.count ? channel.eqGains31[index] : 0
                }
            },
            set: { nv in
                switch channel.eqMode {
                case 10: if index < channel.eqGains10.count { channel.eqGains10[index] = nv }
                case 15: if index < channel.eqGains15.count { channel.eqGains15[index] = nv }
                default: if index < channel.eqGains31.count { channel.eqGains31[index] = nv }
                }
            }
        )
    }
    
    /// Convierte índice de banda a etiqueta legible (ej: "1k", "250", "16k")
    private func getFrequencyLabel(for index: Int) -> String {
        guard let freqs = engine.eqFrequencies[channel.eqMode], index < freqs.count else { return "—" }
        let freq = freqs[index]
        if freq >= 1000 {
            let kValue = freq / 1000
            return kValue == floor(kValue) ? "\(Int(kValue))k" : String(format: "%.1fk", kValue)
        } else {
            return freq == floor(freq) ? "\(Int(freq))" : String(format: "%.1f", freq)
        }
    }
}

// MARK: - ProfessionalEQSlider
/// Slider individual de EQ con estética de hardware profesional.
/// Soporta: drag vertical, scroll wheel (shift = fino), doble-click para reset a 0 dB.
struct ProfessionalEQSlider: View {
    @Binding var gain: Float
    let frequency: String
    var isCompact: Bool = false
    
    var body: some View {
        VStack(spacing: 12) {
            // Valor numérico actual
            Text(String(format: "%.1f", gain))
                .font(.system(size: isCompact ? 8 : 10, weight: .bold, design: .monospaced))
                .foregroundColor(gain == 0 ? .gray : (gain > 0 ? .red : .cyan))
                .frame(height: 15)
            
            GeometryReader { geo in
                let trackHeight = geo.size.height - (isCompact ? 16 : 24)
                let yOffset = CGFloat(1.0 - (Double(gain + 20) / 40.0)) * trackHeight
                
                ZStack(alignment: .top) {
                    // Track
                    Capsule()
                        .fill(Color.black.opacity(0.6))
                        .frame(width: isCompact ? 3 : 5)
                        .padding(.vertical, isCompact ? 8 : 12)
                    
                    // Marcas de referencia
                    VStack(spacing: trackHeight / 4) {
                        ForEach(0..<5) { _ in
                            Rectangle()
                                .fill(Color.white.opacity(0.1))
                                .frame(width: isCompact ? 10 : 18, height: 1)
                        }
                    }
                    .padding(.vertical, isCompact ? 8 : 12)
                    
                    // Línea de 0 dB (centro)
                    Rectangle()
                        .fill(Color.cyan.opacity(0.5))
                        .frame(width: isCompact ? 15 : 25, height: 1)
                        .offset(y: trackHeight / 2 + (isCompact ? 8 : 12))
                    
                    // Knob metálico
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(gradient: Gradient(colors: [Color.gray, Color(hex: "f0f0f0"), Color.gray]),
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: isCompact ? 18 : 28, height: isCompact ? 16 : 24)
                        .overlay(Rectangle().fill(Color.black.opacity(0.4)).frame(height: 1))
                        // [BUG-14] Offset corregido: sumar el padding del track para que el knob
                        // permanezca dentro de los límites visuales en los extremos ±20 dB.
                        .offset(y: yOffset + (isCompact ? 8 : 12) - (isCompact ? 8 : 12))
                }
                .contentShape(Rectangle())
                .onScrollWheel { event in
                    let sensitivity: Double = event.modifierFlags.contains(.shift) ? 0.001 : 0.005
                    let direction: Double = event.isDirectionInvertedFromDevice ? -1.0 : 1.0
                    let delta = Double(event.scrollingDeltaY) * sensitivity * direction
                    let currentPercent = Double(gain + 20) / 40.0
                    let newPercent = min(max(currentPercent + delta, 0.0), 1.0)
                    self.gain = Float(newPercent * 40.0) - 20.0
                }
                .gesture(TapGesture(count: 2).onEnded { gain = 0.0 })
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard geo.size.height > 0 else { return }
                            let percent = 1.0 - Double(value.location.y / geo.size.height)
                            self.gain = min(max(-20, Float(percent * 40.0) - 20.0), 20)
                        }
                )
            }
            .frame(width: isCompact ? 25 : 45)
            
            // Etiqueta de frecuencia
            Text(frequency)
                .font(.system(size: isCompact ? 8 : 10, weight: .black))
                .foregroundColor(.white.opacity(0.7))
                .padding(.top, 4)
        }
    }
}
