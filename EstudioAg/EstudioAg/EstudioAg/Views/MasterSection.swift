import SwiftUI
import Combine
import UniformTypeIdentifiers

/**
 * MasterSection.swift — Panel Master/PFL de la Consola Estudio Ag
 *
 * REFACTOR v10:
 * - @EnvironmentObject para engine y persistence (sin .shared en vistas)
 * - ClockView aislado para evitar re-renders del panel completo cada segundo
 * - OutputSelectorRow desacoplado del singleton
 */

// MARK: - ClockView (TimelineView — Optimizado)
struct ClockView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(context.date, style: .time)
                .font(.system(size: 45, weight: .black, design: .monospaced))
                .foregroundColor(.white)
        }
    }
}

// MARK: - TransmissionTimerView (TimelineView — Optimizado)
struct TransmissionTimerView: View {
    let startDate: Date?
    
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let start = startDate {
                let elapsed = context.date.timeIntervalSince(start)
                let hours = Int(elapsed) / 3600
                let minutes = (Int(elapsed) % 3600) / 60
                let seconds = Int(elapsed) % 60
                
                HStack(spacing: 6) {
                    Text("TIEMPO TRANSMISIÓN:")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    
                    Text(String(format: "%02d:%02d:%02d", hours, minutes, seconds))
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundColor(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.4))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.red.opacity(0.4), lineWidth: 1)
                        )
                        .shadow(color: .red.opacity(0.2), radius: 3)
                }
            }
        }
    }
}

// MARK: - MasterSectionView
struct MasterSectionView: View {
    @EnvironmentObject var engine: RadioAudioEngine
    @EnvironmentObject var persistence: ConsolePersistenceManager
    @EnvironmentObject var vuStore: VUTelemetryStore
    
    @State private var selectedRecordFormat: RecordFormat = .m4a
    @State private var recordDestinationURL: URL? = nil
    @ObservedObject private var recorder = MasterRecorder.shared
    
    var body: some View {
        VStack(spacing: 12) {
            // RELOJ
            ClockView()
                .padding(.top, 15)
            
            // BOTÓN DE EMISIÓN (Ocupa el espacio anterior de los selectores)
            VStack(spacing: 4) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) { engine.isOnAir.toggle() }
                }) {
                    Text(engine.isOnAir ? "AL AIRE" : "FUERA DE AIRE")
                        .font(.system(size: 16, weight: .black)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(engine.isOnAir ? Color.red : Color.gray.opacity(0.25))
                        .cornerRadius(6)
                        .shadow(color: engine.isOnAir ? .red.opacity(0.5) : .clear, radius: 10)
                }
                .buttonStyle(PlainButtonStyle())
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(engine.isOnAir ? Color.green : Color.red.opacity(0.6))
                        .frame(width: 5, height: 5)
                    Text(engine.isOnAir ? "SALIDA GENERAL HABILITADA (EMITIENDO)" : "SALIDA GENERAL DESACTIVADA (MUTEADA)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(engine.isOnAir ? .green : .red.opacity(0.6))
                }
                .padding(.top, 2)
                
                if engine.isOnAir {
                    TransmissionTimerView(startDate: engine.onAirStartDate)
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 15)
            
            // CONTROLES MASTER + PFL (LADO A LADO)
            HStack(spacing: 8) {
                // Master Bus — Solo actualiza engine, Combine sync se encarga de persistir
                MasterStripView(
                    title: "MASTER BUS", color: .red,
                    volume: Binding(
                        get: { engine.volumeStudio },
                        set: { engine.setMasterVolume($0) }
                    ),
                    pan: Binding(
                        get: { engine.masterPan },
                        set: { engine.setMasterPan($0) }
                    ),
                    vuLeft: vuStore.masterVULeft, vuRight: vuStore.masterVURight
                )
                .frame(maxWidth: .infinity)
                
                // PFL / Monitor
                MasterStripView(
                    title: "PFL / MONITOR", color: .cyan,
                    volume: Binding(
                        get: { engine.volumePhones },
                        set: { engine.setPFLVolume($0) }
                    ),
                    pan: Binding(
                        get: { engine.pflPan },
                        set: { engine.setPFLPan($0) }
                    ),
                    vuLeft: vuStore.pflVULeft, vuRight: vuStore.pflVURight
                )
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)
            
            // BOTÓN SYNC MONITORS
            Button(action: {
                engine.isMonitoringSynced.toggle()
                if engine.isMonitoringSynced {
                    engine.setMasterVolume(engine.volumeStudio)
                    engine.setMasterPan(engine.masterPan)
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: engine.isMonitoringSynced ? "link" : "link.badge.plus")
                    Text("SYNC MONITORS").font(.system(size: 9, weight: .black))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(engine.isMonitoringSynced ? Color.cyan : Color.white.opacity(0.1))
                .foregroundColor(engine.isMonitoringSynced ? .black : .white)
                .cornerRadius(4)
            }
            .buttonStyle(PlainButtonStyle())
            
            // GRABADOR MASTER POST-PRODUCCIÓN
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill")
                        .foregroundColor(recorder.isRecording ? .red : .gray)
                        .scaleEffect(recorder.isRecording ? 1.1 : 1.0)
                    Text("MASTER RECORDER")
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    if recorder.isRecording {
                        Text(recorder.durationString)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal, 4)
                
                HStack(spacing: 8) {
                    // Selector de formato
                    Picker("Format", selection: $selectedRecordFormat) {
                        ForEach(RecordFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(maxWidth: .infinity)
                    .labelsHidden()
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                    .disabled(recorder.isRecording)
                    
                    // Botón elegir destino
                    Button(action: selectRecordDestination) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                            Text("DESTINO").font(.system(size: 9, weight: .black))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.white.opacity(0.1))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(recorder.isRecording)
                }
                
                if let path = recordDestinationURL {
                    Text(path.lastPathComponent)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 2)
                } else {
                    Text("Ningún destino seleccionado")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(.top, 2)
                }
                
                // Botón Iniciar/Detener
                Button(action: toggleRecording) {
                    HStack(spacing: 6) {
                        if recorder.isConverting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.6)
                            Text("CONVIRTIENDO...")
                                .font(.system(size: 11, weight: .black))
                        } else {
                            Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle")
                            Text(recorder.isRecording ? "DETENER GRABACIÓN" : "INICIAR GRABACIÓN")
                                .font(.system(size: 11, weight: .black))
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 38)
                    .background(
                        recorder.isConverting ? Color.orange :
                        (recorder.isRecording ? Color.red : 
                        (recordDestinationURL == nil ? Color.white.opacity(0.1) : Color.green))
                    )
                    .foregroundColor(recordDestinationURL == nil && !recorder.isRecording && !recorder.isConverting ? .white.opacity(0.4) : .white)
                    .cornerRadius(6)
                    .shadow(color: recorder.isRecording ? .red.opacity(0.3) : .clear, radius: 6)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled((recordDestinationURL == nil && !recorder.isRecording) || recorder.isConverting)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.3))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.05), lineWidth: 1))
            )
            .padding(.horizontal, 15)
            
            // SELECTORES DE SALIDA (Debajo del grabador, excluyendo streaming)
            VStack(spacing: 12) {
                OutputSelectorGroup(bus: .master)
                OutputSelectorGroup(bus: .pfl)
            }
            .padding(.horizontal, 15)
            
            Spacer()
        }
    }
    
    func selectRecordDestination() {
        let panel = NSSavePanel()
        
        let contentType: UTType
        switch selectedRecordFormat {
        case .wav: contentType = .wav
        case .m4a: contentType = .mpeg4Audio
        case .mp3: contentType = .mp3
        }
        panel.allowedContentTypes = [contentType]
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        panel.nameFieldStringValue = "EstudioAg_Master_\(timestamp).\(selectedRecordFormat.fileExtension)"
        
        panel.title = "Guardar Grabación Master"
        panel.message = "Selecciona la carpeta y el nombre para guardar la grabación post-producción."
        
        if panel.runModal() == .OK {
            recordDestinationURL = panel.url
        }
    }
    
    func toggleRecording() {
        if recorder.isRecording {
            recorder.stopRecording()
        } else if let url = recordDestinationURL {
            do {
                try recorder.startRecording(to: url, format: selectedRecordFormat)
            } catch {
                print("❌ [UI] Error al iniciar grabación: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - OutputSelectorGroup
/// Grupo de selectores de salida para un bus (GENERAL o PFL).
/// Soporta hasta AudioEngineCore.maxExtraOutputs destinos adicionales en paralelo.
struct OutputSelectorGroup: View {
    let bus: AudioOutputBus
    @EnvironmentObject var engine: RadioAudioEngine
    @EnvironmentObject var persistence: ConsolePersistenceManager
    
    private var displayTitle: String {
        switch bus {
        case .streaming: return "STREAMING"
        case .master:    return "GENERAL"
        case .pfl:       return "PFL / MON"
        }
    }
    private var icon: String {
        switch bus {
        case .streaming: return "antenna.radiowaves.left.and.right"
        case .master:    return "speaker.wave.3.fill"
        case .pfl:       return "headphones"
        }
    }
    private var accentColor: Color {
        bus == .pfl ? .cyan : .green
    }
    
    /// Slots extra del bus actual
    private var extraOutputs: [(uid: String, name: String)] {
        bus == .pfl ? engine.extraPFLOutputs : engine.extraGeneralOutputs
    }
    
    /// Binding del selector primario (dispositivo principal del bus)
    private var primaryDevice: Binding<String> {
        Binding(
            get: {
                let savedName: String; let savedUID: String
                switch bus {
                case .streaming: savedName = persistence.state.selectedOutputStreamingName; savedUID = persistence.state.selectedOutputStreamingUID
                case .pfl:       savedName = persistence.state.selectedOutputPFLName;       savedUID = persistence.state.selectedOutputPFLUID
                case .master:    savedName = persistence.state.selectedOutputGeneralName;   savedUID = persistence.state.selectedOutputGeneralUID
                }
                let valid = engine.outputDevices.first(where: { $0.uid == savedUID })
                return valid != nil ? savedName : "Ninguna"
            },
            set: { newValue in
                switch bus {
                case .streaming: persistence.state.selectedOutputStreamingName = newValue
                case .pfl:       persistence.state.selectedOutputPFLName = newValue
                case .master:    persistence.state.selectedOutputGeneralName = newValue
                }
                engine.applyOutputDevice(newValue, for: bus)
            }
        )
    }
    
    /// Binding para un slot extra en el índice dado
    private func extraBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard index < extraOutputs.count else { return "Ninguna" }
                let item = extraOutputs[index]
                let valid = engine.outputDevices.first(where: { $0.uid == item.uid })
                return valid != nil ? item.name : "Ninguna"
            },
            set: { newValue in engine.updateExtraOutput(at: index, name: newValue, for: bus) }
        )
    }
    
    var body: some View {
        let devices = engine.outputDevices.map(\.name)
        let atLimit = extraOutputs.count >= AudioEngineCore.maxExtraOutputs
        
        VStack(spacing: 8) {
            // ── Cabecera ──────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11))
                Text(displayTitle).font(.system(size: 11, weight: .black))
                
                if !extraOutputs.isEmpty {
                    Text("+\(extraOutputs.count)").font(.system(size: 9, weight: .bold))
                        .foregroundColor(accentColor)
                }
                Spacer()
                
                // Botón "+" para añadir un nuevo destino
                Button(action: { withAnimation { engine.addExtraOutputSlot(for: bus) } }) {
                    Image(systemName: atLimit ? "plus.circle" : "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(atLimit ? .white.opacity(0.2) : accentColor)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(atLimit)
                .help(atLimit ? "Máximo de salidas alcanzado" : "Añadir otra salida física para \(displayTitle)")
                
                Button(action: { engine.scanDevices() }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10)).foregroundColor(.white.opacity(0.3))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .foregroundColor(.gray)
            .padding(.horizontal, 4)
            
            // ── Divisor ──────────────────────────────────────
            Rectangle().fill(accentColor.opacity(0.25)).frame(height: 1)
            
            // ── Selector Primario ─────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundColor(accentColor)
                Picker("", selection: primaryDevice) {
                    Text("Ninguna").tag("Ninguna")
                    ForEach(devices, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(MenuPickerStyle()).labelsHidden()
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.05)))
                .frame(maxWidth: .infinity)
            }
            
            // ── Selectores Extra (multi-destino funcionales) ──
            ForEach(Array(extraOutputs.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.right.down")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.3))
                    
                    Picker("", selection: extraBinding(at: index)) {
                        Text("Ninguna").tag("Ninguna")
                        ForEach(devices, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(MenuPickerStyle()).labelsHidden()
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.05)))
                    .frame(maxWidth: .infinity)
                    
                    // Indicador de estado activo
                    Circle()
                        .fill(item.uid.isEmpty ? Color.gray.opacity(0.3) : accentColor)
                        .frame(width: 6, height: 6)
                    
                    Button(action: {
                        withAnimation { engine.removeExtraOutput(at: index, for: bus) }
                    }) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red.opacity(0.7))
                            .font(.system(size: 14))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.25))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(accentColor.opacity(0.15), lineWidth: 1))
        )
    }
}

// MARK: - KnobView (Perilla Estilo Consola)
struct KnobView: View {
    let label: String
    @Binding var value: Double
    @State private var startValue: Double? = nil
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 4).frame(width: 60, height: 60)
                Circle().trim(from: 0, to: CGFloat(value) * 0.75)
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 60, height: 60).rotationEffect(.degrees(135))
                Capsule().fill(Color.white).frame(width: 3, height: 15)
                    .offset(y: -22).rotationEffect(.degrees(Double(value) * 270 - 135))
            }
            .contentShape(Circle())
            .onScrollWheel { event in
                let delta = -Double(event.scrollingDeltaY) * 0.005
                value = min(max(value + delta, 0.0), 1.0)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if startValue == nil { startValue = value }
                        let delta = -Double(gesture.translation.height) * 0.005
                        if let start = startValue { value = min(1.0, max(0.0, start + delta)) }
                    }
                    .onEnded { _ in startValue = nil }
            )
            Text(label).font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.6))
        }
    }
}

// MARK: - MasterStripView (Fader + VU para Master/PFL)
struct MasterStripView: View {
    let title: String
    let color: Color
    @Binding var volume: Double
    @Binding var pan: Double
    var vuLeft: Double
    var vuRight: Double
    
    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .black))
                .foregroundColor(color.opacity(0.8))
                .lineLimit(1)
            
            HStack(alignment: .bottom, spacing: 6) {
                VStack(spacing: 4) {
                    VerticalFader(value: $volume).frame(width: 26, height: 145)
                    Text("\(Int(volume * 100))%")
                        .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(color)
                }
                
                VStack(spacing: 8) {
                    HStack(spacing: 3) {
                        VUMeterView(value: vuLeft, width: 8)
                        VUMeterView(value: vuRight, width: 8)
                    }
                    .frame(height: 115)
                    HorizontalPanSlider(value: $pan)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.4))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.2), lineWidth: 1))
            )
            .clipped()
        }
    }
}
