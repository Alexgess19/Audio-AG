import SwiftUI
import Combine
import ScreenCaptureKit

/**
 * MainConsoleView.swift — Vista Principal de la Consola Audio AG
 *
 * REFACTOR v10:
 * - @EnvironmentObject en lugar de .shared (testeable, desacoplado)
 * - Bindings sincronizados: eliminan TODOS los .onChange de parámetros DSP
 * - isSourceOffline: prioriza señal real (qSamples > 0) sobre nombre
 */
struct MainConsoleView: View {
    @EnvironmentObject var engine: RadioAudioEngine
    @EnvironmentObject var persistence: ConsolePersistenceManager
    @State private var showingSettings = false
    
    var body: some View {
        ZStack {
            Color(hex: "0a0a12").ignoresSafeArea()
            
            VStack(spacing: 0) {
                HeaderView(showingSettings: $showingSettings)
                
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 40) {
                        // SECCIÓN: MICRÓFONOS
                        ChannelSection(title: "MICRÓFONOS", icon: "mic.fill", color: .orange) {
                            ForEach($persistence.state.micChannels) { $ch in
                                ChannelStripView(channel: $ch, onDelete: { persistence.deleteChannel(id: ch.id, type: .mic, engine: engine) })
                            }
                            AddChannelButton(type: .mic) { persistence.addChannel(type: .mic, engine: engine) }
                        }
                        
                        // SECCIÓN: LÍNEAS / APPS
                        ChannelSection(title: "LÍNEAS / APPS", icon: "cable.connector", color: .green) {
                            ForEach($persistence.state.hwChannels) { $ch in
                                ChannelStripView(channel: $ch, onDelete: { persistence.deleteChannel(id: ch.id, type: .hardware, engine: engine) })
                            }
                            ForEach($persistence.state.appChannels) { $ch in
                                ChannelStripView(channel: $ch, onDelete: { persistence.deleteChannel(id: ch.id, type: .app, engine: engine) })
                            }
                            AddChannelButton(type: .hardware) { persistence.addChannel(type: .hardware, engine: engine) }
                        }
                    }
                    .padding(30)
                    .padding(.trailing, 320)
                }
                
                Spacer()
            }
            
            // Panel Master (Derecha)
            HStack {
                Spacer()
                MasterSectionView()
                    .frame(width: 320)
                    .background(
                        VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                            .overlay(Rectangle().fill(Color.white.opacity(0.05)).frame(width: 1), alignment: .leading)
                    )
            }
        }
    }
}

// MARK: - ChannelSection
struct ChannelSection<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    let content: Content
    
    init(title: String, icon: String, color: Color, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.color = color; self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundColor(color).font(.system(size: 18, weight: .bold))
                Text(title).font(.system(size: 16, weight: .black)).foregroundColor(.white)
            }
            .padding(.leading, 10)
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 15)], spacing: 15) {
                content
            }
        }
    }
}

// MARK: - ChannelStripView
/// Tira de canal profesional. Usa bindings sincronizados para eliminar .onChange.
/// Cada setter de binding llama al engine automáticamente → UI limpia sin callbacks.
struct ChannelStripView: View {
    @Binding var channel: RadioChannel
    var onDelete: () -> Void
    @EnvironmentObject var engine: RadioAudioEngine
    @EnvironmentObject var vuStore: VUTelemetryStore
    @ObservedObject var appCapture = AppCaptureManager.shared
    @State private var showingDeleteAlert = false
    
    private var isFused: Bool { channel.type == .app || channel.type == .hardware }
    
    // MARK: Synced Bindings (reemplazan TODOS los .onChange de DSP)
    // Cada binding actualiza el modelo Y el engine en un solo paso.
    
    /// Volumen: sincroniza fader → engine en cada cambio
    private var syncedVolume: Binding<Double> {
        Binding(
            get: { channel.volume },
            set: { nv in channel.volume = nv; engine.setVolume(nv, for: channel.id) }
        )
    }
    
    /// Pan: sincroniza panorama → engine
    private var syncedPan: Binding<Double> {
        Binding(
            get: { channel.pan },
            set: { nv in channel.pan = nv; engine.setPan(nv, for: channel.id) }
        )
    }
    
    /// Fuente de audio: sincroniza selector → ruteo del engine
    private var syncedSource: Binding<String> {
        Binding(
            get: { channel.selectedSourceDisplayName },
            set: { nv in
                let old = channel.selectedSourceDisplayName
                channel.selectedSourceDisplayName = nv
                if old != nv {
                    print("🎙️ [UI] Canal '\(channel.name)': Fuente cambiada de \(old) a \(nv)")
                    let sid = engine.setSource(nv, for: channel.id, type: channel.type)
                    channel.sourceID = sid
                }
            }
        )
    }
    
    private var displayApps: [String] {
        var apps = appCapture.capturableApps.map(\.applicationName)
        if channel.type == .app && channel.selectedSourceDisplayName != "Ninguna" && !apps.contains(channel.selectedSourceDisplayName) {
            apps.append(channel.selectedSourceDisplayName)
        }
        return apps
    }
    
    private var displayHws: [String] {
        var filtered = engine.inputDevices.map(\.name)
        if (channel.type == .hardware || channel.type == .mic) && channel.selectedSourceDisplayName != "Ninguna" && !filtered.contains(channel.selectedSourceDisplayName) {
             filtered.append(channel.selectedSourceDisplayName)
        }
        return filtered
    }
    
    private var filteredSources: [String] {
        // [BUG-10] Filtro preciso: excluir solo los dispositivos claramente integrados del Mac
        // (micrófono interno y altavoz interno), sin ocultar interfaces externas que puedan
        // tener nombres similares. Se usan prefijos exactos del sistema para minimizar falsos positivos.
        let builtInPrefixes = ["Built-in Microphone", "MacBook Pro Microphone",
                               "MacBook Air Microphone", "Built-in Input"]
        if isFused {
            return displayHws.filter { name in
                !builtInPrefixes.contains(where: { name.hasPrefix($0) })
            }
        }
        return displayHws
    }
    
    /// Detección de fuente offline: prioriza señal real sobre nombre
    private func isSourceOffline(_ source: String) -> Bool {
        let clean = source.trimmingCharacters(in: .whitespaces).lowercased()
        if clean == "ninguna" || clean.isEmpty { return false }
        if let snap = vuStore.channelMonitor[channel.id], snap.qSamples > 0 { return false }
        
        let isApp = appCapture.capturableApps.contains { $0.applicationName.lowercased().contains(clean) }
        let isDevice = engine.inputDevices.contains { $0.name.lowercased().contains(clean) }
        
        return !(isApp || isDevice)
    }

    var body: some View {
        VStack(spacing: 10) {
            // CABECERA: Selector + Nombre + Botón cerrar
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: syncedSource) {
                        Text("Ninguna").tag("Ninguna")
                        
                        if isFused {
                            Divider()
                            ForEach(displayApps, id: \.self) { source in
                                let offline = isSourceOffline(source)
                                HStack {
                                    Image(systemName: offline ? "exclamationmark.triangle.fill" : "waveform.circle.fill")
                                        .foregroundColor(offline ? .gray : .cyan)
                                    Text(source).foregroundColor(offline ? .gray : .white)
                                }.tag(source)
                            }
                            Divider()
                            ForEach(filteredSources, id: \.self) { source in
                                let offline = isSourceOffline(source)
                                HStack {
                                    Image(systemName: offline ? "mic.slash.fill" : "mic.fill")
                                        .foregroundColor(offline ? .gray : .orange)
                                    Text(source).foregroundColor(offline ? .gray : .white)
                                }.tag(source)
                            }
                        } else {
                            Divider()
                            ForEach(filteredSources, id: \.self) { source in
                                let offline = isSourceOffline(source)
                                HStack {
                                    Image(systemName: offline ? "mic.slash.fill" : "mic.fill")
                                        .foregroundColor(offline ? .gray : .orange)
                                    Text(source).foregroundColor(offline ? .gray : .white)
                                }.tag(source)
                            }
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .scaleEffect(0.8)
                    .frame(height: 20)
                    
                    Text(channel.name)
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundColor(channel.isLive ? .red : .cyan)
                }
                
                Spacer()
                
                Button(action: { showingDeleteAlert = true }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.red.opacity(0.3))
                        .padding(2)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Cerrar Fader")
                .alert("Cerrar Canal", isPresented: $showingDeleteAlert) {
                    Button("Cerrar", role: .destructive, action: onDelete)
                    Button("Cancelar", role: .cancel) {}
                } message: {
                    Text("¿Está seguro que quiere cerrar este fader? Se detendrá la captura de audio de \(channel.name).")
                }
            }
            
            // CUERPO: FADER + ESCALA + PAN/VU/BOTONES
            HStack(alignment: .bottom, spacing: 6) {
                // Fader usa syncedVolume → sin .onChange
                VerticalFader(value: syncedVolume)
                    .frame(width: 32, height: 160)
                
                // Escala dB
                VStack(spacing: 0) {
                    GeometryReader { geo in
                        let h = geo.size.height
                        ZStack(alignment: .topLeading) {
                            dbLabel("0",    color: .red,    yFrac: 0.00, height: h)
                            dbLabel("-10",  color: .orange, yFrac: 0.35, height: h)
                            dbLabel("-20",  color: .yellow, yFrac: 0.60, height: h)
                            dbLabel("-40",  color: .green,  yFrac: 0.82, height: h)
                            dbLabel("-∞",   color: .gray,   yFrac: 0.96, height: h)
                        }
                    }
                }
                .frame(width: 22, height: 160)
                .font(.system(size: 6, weight: .bold, design: .monospaced))
                
                VStack(spacing: 8) {
                    // Pan usa syncedPan → sin .onChange
                    HorizontalPanSlider(value: syncedPan)
                        .frame(height: 15)
                    
                    HStack(alignment: .bottom, spacing: 6) {
                        // VU Meters (ahora Canvas — GPU acelerado)
                        let vu = vuStore.channelVULevels[channel.id]
                        HStack(spacing: 2) {
                            VUMeterView(value: vu?.left ?? -96.0, width: 8)
                            VUMeterView(value: vu?.right ?? -96.0, width: 8)
                        }
                        .frame(height: 130)
                        
                        ChannelActionButtons(channel: $channel)
                    }
                }
            }
            
            // Indicador %
            Text("\(Int(channel.volume * 100))%")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(.cyan)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.05))
                .cornerRadius(4)
        }
        .padding(12)
        .frame(width: 210)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: "15151e"))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(channel.isLive ? Color.red.opacity(0.4) : Color.white.opacity(0.05), lineWidth: 1.5)
                )
        )
    }
    
    private func dbLabel(_ text: String, color: Color, yFrac: CGFloat, height: CGFloat) -> some View {
        Text(text).foregroundColor(color).offset(y: height * yFrac)
    }
}

// MARK: - ChannelActionButtons
/// Botones VIVO, PFL, EQ, GAIN, RANGE — usan bindings sincronizados
struct ChannelActionButtons: View {
    @Binding var channel: RadioChannel
    @EnvironmentObject var engine: RadioAudioEngine
    @State private var showingEQ = false
    @State private var showingGain = false
    @State private var showingFilter = false
    
    /// Pre-Gain sincronizado con engine
    private var syncedPreGain: Binding<Double> {
        Binding(
            get: { channel.preGain },
            set: { nv in channel.preGain = nv; engine.setPreGain(nv, for: channel.id) }
        )
    }
    
    /// Gate sincronizado
    private var syncedGate: Binding<Double> {
        Binding(
            get: { channel.gateThreshold },
            set: { nv in channel.gateThreshold = nv; engine.setGateThreshold(nv, for: channel.id) }
        )
    }
    
    /// Limiter sincronizado
    private var syncedLimit: Binding<Double> {
        Binding(
            get: { channel.limitThreshold },
            set: { nv in channel.limitThreshold = nv; engine.setLimitThreshold(nv, for: channel.id) }
        )
    }
    
    var body: some View {
        let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
        LazyVGrid(columns: columns, spacing: 8) {
            // VIVO (AL AIRE)
            Button(action: {
                channel.isLive.toggle()
                engine.setLive(channel.isLive, for: channel.id)
                print("\(channel.isLive ? "🔴" : "⚪️") [UI] Canal '\(channel.name)': Salida al Aire \(channel.isLive ? "Activada" : "Desactivada")")
            }) {
                Text("VIVO")
                    .font(.system(size: 9, weight: .black))
                    .foregroundColor(channel.isLive ? .white : .red)
                    .frame(height: 26)
                    .frame(maxWidth: .infinity)
                    .background(channel.isLive ? Color.red : Color.red.opacity(0.1))
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.red.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(PlainButtonStyle())
            
            // PFL
            Button(action: {
                channel.isPFL.toggle()
                engine.setPFL(channel.isPFL, for: channel.id)
                print("\(channel.isPFL ? "🔵" : "⚪️") [UI] Canal '\(channel.name)': PFL \(channel.isPFL ? "Activado" : "Desactivado")")
            }) {
                Text("PFL")
                    .font(.system(size: 9, weight: .black))
                    .foregroundColor(channel.isPFL ? .white : .cyan)
                    .frame(height: 26)
                    .frame(maxWidth: .infinity)
                    .background(channel.isPFL ? Color.cyan : Color.cyan.opacity(0.1))
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.cyan.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(PlainButtonStyle())
            
            // EQ
            Button(action: { showingEQ = true }) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(height: 26)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(4)
            }
            .buttonStyle(PlainButtonStyle())
            .popover(isPresented: $showingEQ) {
                EQView(channel: $channel)
            }
            
            // Controles exclusivos de micrófono
            if channel.type == .mic {
                // GAIN — usa syncedPreGain, sin .onChange
                Button(action: { showingGain = true }) {
                    VStack(spacing: 0) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 10))
                        Text("GAIN").font(.system(size: 7, weight: .black))
                    }
                    .foregroundColor(.orange)
                    .frame(height: 26)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.orange.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
                .popover(isPresented: $showingGain) {
                    MicGainControl(gain: syncedPreGain)
                }
                
                // FILTER (RANGE) — usa syncedGate y syncedLimit, sin .onChange
                Button(action: { showingFilter = true }) {
                    VStack(spacing: 0) {
                        Image(systemName: "waveform.and.mic").font(.system(size: 10))
                        Text("RANGE").font(.system(size: 7, weight: .black))
                    }
                    .foregroundColor(.green)
                    .frame(height: 26)
                    .frame(maxWidth: .infinity)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.green.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
                .popover(isPresented: $showingFilter) {
                    VStack(spacing: 12) {
                        Text("FILTRO DE RANGO (dBFS)")
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(.green)
                        
                        RangeSlider(lowerValue: syncedGate, upperValue: syncedLimit)
                        
                        HStack {
                            VStack(alignment: .leading) {
                                Text("GATE (SUSURRO)").font(.system(size: 7, weight: .bold))
                                Text(String(format: "%.1f dB", channel.gateThreshold)).font(.system(size: 9)).monospacedDigit()
                            }
                            .foregroundColor(.orange)
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("LIMIT (GRITO)").font(.system(size: 7, weight: .bold))
                                Text(String(format: "%.1f dB", channel.limitThreshold)).font(.system(size: 9)).monospacedDigit()
                            }
                            .foregroundColor(.cyan)
                        }
                    }
                    .padding(15)
                    .frame(width: 240)
                    .background(Color(hex: "1a1a25"))
                }
                
                // ISOLATION (VOICE PROCESSING)
                Button(action: {
                    channel.isVoiceIsolationEnabled.toggle()
                    engine.setVoiceIsolation(channel.isVoiceIsolationEnabled, for: channel.id)
                }) {
                    VStack(spacing: 0) {
                        Image(systemName: channel.isVoiceIsolationEnabled ? "mic.badge.xmark" : "waveform.circle").font(.system(size: 10))
                        Text("VOICE").font(.system(size: 7, weight: .black))
                    }
                    .foregroundColor(channel.isVoiceIsolationEnabled ? .purple : .gray)
                    .frame(height: 26)
                    .frame(maxWidth: .infinity)
                    .background(channel.isVoiceIsolationEnabled ? Color.purple.opacity(0.2) : Color.white.opacity(0.05))
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(channel.isVoiceIsolationEnabled ? Color.purple.opacity(0.5) : Color.clear, lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
                .help("Cancelación de ruido ambiental y eco")
            } else {
                // KARAOKE (VOCAL CANCEL)
                Button(action: {
                    channel.isKaraokeEnabled.toggle()
                    engine.setKaraoke(channel.isKaraokeEnabled, for: channel.id)
                }) {
                    VStack(spacing: 0) {
                        Image(systemName: "music.mic").font(.system(size: 10))
                        Text("VOCAL").font(.system(size: 7, weight: .black))
                    }
                    .foregroundColor(channel.isKaraokeEnabled ? .yellow : .gray)
                    .frame(height: 26)
                    .frame(maxWidth: .infinity)
                    .background(channel.isKaraokeEnabled ? Color.yellow.opacity(0.2) : Color.white.opacity(0.05))
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(channel.isKaraokeEnabled ? Color.yellow.opacity(0.5) : Color.clear, lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
                .help("Anulación de voz (Vocal Cancel)")
            }
        }
    }
}

// MARK: - AddChannelButton
struct AddChannelButton: View {
    let type: ChannelType
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus.circle.fill").font(.system(size: 24))
                Text("AÑADIR").font(.system(size: 10, weight: .bold))
            }
            .foregroundColor(.white.opacity(0.3))
            .frame(width: 190, height: 280)
            .background(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [5])))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - HeaderView
struct HeaderView: View {
    @Binding var showingSettings: Bool
    @State private var showingMonitor = false
    @EnvironmentObject var engine: RadioAudioEngine
    
    var body: some View {
        HStack {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 24, weight: .black))
                .foregroundColor(.cyan)
            
            Text("AUDIO AG").font(.system(size: 20, weight: .black)).foregroundColor(.white)
            Text("BROADCAST CONSOLE").font(.system(size: 10, weight: .bold)).foregroundColor(.cyan.opacity(0.6)).padding(.leading, 5)
            
            Spacer()
            
            Button(action: { showingMonitor = true }) {
                HStack(spacing: 5) {
                    Image(systemName: "scope").font(.system(size: 13, weight: .bold))
                    Text("SEÑAL").font(.system(size: 9, weight: .black))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.cyan.opacity(0.12))
                .foregroundColor(.cyan)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.cyan.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(PlainButtonStyle())
            .sheet(isPresented: $showingMonitor) {
                SignalMonitorView()
            }
            .padding(.trailing, 8)
            
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape.fill").font(.system(size: 18)).foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 30)
        .frame(height: 80)
        .background(Color.black.opacity(0.3))
    }
}

// MARK: - VisualEffectView (NSVisualEffectView bridge)
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material; view.blendingMode = blendingMode; view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material; nsView.blendingMode = blendingMode
    }
}

// MARK: - Color Hex Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}
