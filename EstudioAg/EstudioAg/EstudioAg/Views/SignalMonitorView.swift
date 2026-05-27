import SwiftUI
import Combine

/**
 * SignalMonitorView.swift
 * Panel de monitoreo en tiempo real de la cadena de señal completa.
 * Muestra cada canal desde la entrada hasta el bus Master y PFL.
 */
struct SignalMonitorView: View {
    @EnvironmentObject var engine: RadioAudioEngine
    @EnvironmentObject var vuStore: VUTelemetryStore
    @Environment(\.dismiss) private var dismiss

    // Actualización visual cada 100ms
    @State private var tick = false
    private let refreshTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color(hex: "0a0a12").ignoresSafeArea()

            VStack(spacing: 0) {
                // ── HEADER ───────────────────────────────────────────────
                HStack {
                    Image(systemName: "scope")
                        .font(.system(size: 16, weight: .black))
                        .foregroundColor(.cyan)
                    Text("MONITOR DE SEÑAL")
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    // Buses globales
                    BusChip(label: "MASTER", dbL: Float(vuStore.masterVULeft),
                            dbR: Float(vuStore.masterVURight), color: .red)
                    BusChip(label: "PFL", dbL: Float(vuStore.pflVULeft),
                            dbR: Float(vuStore.pflVURight), color: .cyan)
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Color.black.opacity(0.5))

                Divider().background(Color.white.opacity(0.1))

                // ── TABLA DE CANALES ─────────────────────────────────────
                ScrollView(.vertical) {
                    VStack(spacing: 2) {
                        // Encabezado de columnas
                        ChannelRowHeader()

                        // Filas de canales en orden de creación
                        let order = engine.channelOrder
                        let monitor = vuStore.channelMonitor
                        let snapshots = order.compactMap { monitor[$0] }
                        
                        if snapshots.isEmpty {
                            Text("Sin canales activos")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white.opacity(0.3))
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else {
                             ForEach(snapshots) { snap in
                                 ChannelMonitorRow(snap: snap, vuLevels: vuStore.channelVULevels[snap.id])
                             }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                Divider().background(Color.white.opacity(0.1))

                // ── LEYENDA ───────────────────────────────────────────────
                HStack(spacing: 20) {
                    LegendItem(color: .green,  label: "Señal OK  (> -40 dBFS)")
                    LegendItem(color: .yellow, label: "Débil  (-60 .. -40)")
                    LegendItem(color: .red,    label: "Clip / Saturación  (> -3)")
                    LegendItem(color: .gray,   label: "Silencio / Sin señal")
                    Spacer()
                    Text("Actualización: 100ms")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.2))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.4))
            }
        }
        .onReceive(refreshTimer) { _ in tick.toggle() }
        .frame(minWidth: 900, minHeight: 500)
    }
}

// MARK: - Encabezado de columnas
private struct ChannelRowHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            col("CANAL",   w: 80)
            col("TIPO",    w: 80)
            col("FUENTE",  w: 130)
            col("IN L",    w: 80)
            col("IN R",    w: 80)
            col("Q buf",   w: 60)
            col("READY",   w: 55)
            col("FADER",   w: 65)
            col("LIVE",    w: 50)
            col("PFL",     w: 50)
            col("POST-EQ L", w: 85)
            col("POST-EQ R", w: 85)
        }
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.05))
        .cornerRadius(4)
    }
    
    @ViewBuilder
    private func col(_ t: String, w: CGFloat) -> some View {
        Text(t)
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .foregroundColor(.white.opacity(0.4))
            .frame(width: w, alignment: .leading)
            .padding(.leading, 4)
    }
}

// MARK: - Fila de canal
private struct ChannelMonitorRow: View {
    let snap: ChannelMonitorSnapshot
    let vuLevels: (left: Double, right: Double)?

    var body: some View {
        let postDbL = Float(vuLevels?.left ?? -96.0)
        let postDbR = Float(vuLevels?.right ?? -96.0)

        HStack(spacing: 0) {
            // Canal
            Text(snap.name)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 80, alignment: .leading).padding(.leading, 4)

            // Tipo
            TypeBadge(type: snap.type)
                .frame(width: 80, alignment: .leading).padding(.leading, 4)

            // Fuente
            Text(snap.sourceDisplayName.isEmpty || snap.sourceDisplayName == "Ninguna" ? "—" : snap.sourceDisplayName)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(snap.sourceDisplayName == "Ninguna" || snap.sourceDisplayName.isEmpty ? .white.opacity(0.2) : .white.opacity(0.8))
                .lineLimit(1).truncationMode(.tail)
                .frame(width: 130, alignment: .leading).padding(.leading, 4)

            // IN L dB
            DbCell(db: snap.inputDbL, width: 80)

            // IN R dB
            DbCell(db: snap.inputDbR, width: 80)

            // Q buffer samples
            Text("\(snap.qSamples)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(snap.qSamples > 0 ? .white.opacity(0.6) : .white.opacity(0.2))
                .frame(width: 60, alignment: .trailing).padding(.trailing, 8)

            // isReady
            StatusDot(on: snap.qReady, onColor: .green, label: snap.qReady ? "SÍ" : "NO")
                .frame(width: 55)

            // Fader %
            Text("\(Int(snap.volume * 100))%")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(snap.volume > 0 ? .cyan : .white.opacity(0.2))
                .frame(width: 65)

            // LIVE
            StatusDot(on: snap.isLive, onColor: .red, label: snap.isLive ? "VIVO" : "OFF")
                .frame(width: 50)

            // PFL
            StatusDot(on: snap.isPFL, onColor: .cyan, label: snap.isPFL ? "PFL" : "OFF")
                .frame(width: 50)

            // POST-EQ L
            DbCell(db: postDbL, width: 85)

            // POST-EQ R
            DbCell(db: postDbR, width: 85)
        }
        .padding(.vertical, 5)
        .background(rowBg)
        .cornerRadius(4)
    }

    private var rowBg: Color {
        if snap.isLive { return Color.red.opacity(0.06) }
        if snap.isPFL  { return Color.cyan.opacity(0.04) }
        return Color.white.opacity(0.02)
    }
}

// MARK: - Celda de dB con color semafórico
private struct DbCell: View {
    let db: Float
    let width: CGFloat

    var body: some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2)
                .fill(barColor)
                .frame(width: barWidth, height: 8)
            Text(db <= -95 ? "–∞" : String(format: "%.1f", db))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(barColor)
        }
        .frame(width: width, alignment: .leading)
        .padding(.leading, 4)
    }

    private var barColor: Color {
        if db <= -95 { return .white.opacity(0.15) }
        if db > -3   { return .red }
        if db > -12  { return .orange }
        if db > -40  { return .green }
        if db > -60  { return .yellow }
        return .white.opacity(0.3)
    }

    private var barWidth: CGFloat {
        if db <= -95 { return 2 }
        // Curva Perceptual: (val+60)/60 -> pow(n, 0.6) para dar más resolución al rango alto
        let linearNorm = CGFloat((db + 60) / 60).clamped(to: 0...1)
        let perceptualNorm = pow(linearNorm, 0.6) 
        return max(2, perceptualNorm * 28)
    }
}

// MARK: - Chip de Bus Global
private struct BusChip: View {
    let label: String
    let dbL: Float
    let dbR: Float
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundColor(color)
            VStack(spacing: 1) {
                dbLine("L", db: dbL, color: color)
                dbLine("R", db: dbR, color: color)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.25), lineWidth: 1))
        .cornerRadius(6)
    }

    private func dbLine(_ ch: String, db: Float, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(ch).font(.system(size: 7, design: .monospaced)).foregroundColor(color.opacity(0.5))
            Text(db <= -95 ? "–∞ dBFS" : String(format: "%+.1f dBFS", db))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(db > -3 ? .red : color)
        }
    }
}

// MARK: - Badge de tipo de canal
private struct TypeBadge: View {
    let type: ChannelType
    var body: some View {
        Text(shortLabel)
            .font(.system(size: 8, weight: .black))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(bgColor.opacity(0.18))
            .foregroundColor(bgColor)
            .cornerRadius(3)
    }
    private var shortLabel: String {
        switch type { case .app: return "APP"; case .mic: return "MIC"; case .hardware: return "HW" }
    }
    private var bgColor: Color {
        switch type { case .app: return .cyan; case .mic: return .orange; case .hardware: return .green }
    }
}

// MARK: - Punto de estado ON/OFF
private struct StatusDot: View {
    let on: Bool
    let onColor: Color
    let label: String
    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(on ? onColor : Color.white.opacity(0.1))
                .frame(width: 6, height: 6)
                .shadow(color: on ? onColor.opacity(0.8) : .clear, radius: 3)
            Text(label)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundColor(on ? onColor : .white.opacity(0.2))
        }
    }
}

// MARK: - Leyenda
private struct LegendItem: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 8)
            Text(label).font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.4))
        }
    }
}

// MARK: - Helpers
extension Float {
    /// Convierte una amplitud lineal a dBFS de forma segura para audio RT
    var toDb: Float {
        if self.isNaN || self.isInfinite || self <= 1e-8 { return -96.0 }
        return 20 * log10(self)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
