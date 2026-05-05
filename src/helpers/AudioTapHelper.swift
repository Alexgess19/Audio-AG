/**
 * AudioTapHelper.swift
 * Captura audio por proceso usando CATapDescription (macOS 14.2+)
 * Emite JSON por stdout cada ~33ms con niveles RMS, dB y % por proceso.
 */
import Foundation
import CoreAudio
import AVFoundation
import Accelerate

// Flush inmediato de stdout (sin buffer)
setbuf(stdout, nil)

// MARK: - Categoría
func detectCategory(name: String, bundleID: String?) -> String {
    let n = name.lowercased()
    let b = (bundleID ?? "").lowercased()
    let music   = ["spotify","music","vlc","tidal","deezer","vox","itunes","swinsian","doppler","capo"]
    let browser = ["safari","chrome","firefox","edge","arc","brave","opera","webkit","chromium"]
    let comms   = ["zoom","discord","slack","teams","facetime","skype","telegram","whatsapp","signal","webex","loom"]
    if music.first(where:   { n.contains($0) || b.contains($0) }) != nil { return "music" }
    if browser.first(where: { n.contains($0) || b.contains($0) }) != nil { return "browser" }
    if comms.first(where:   { n.contains($0) || b.contains($0) }) != nil { return "comms" }
    return "other"
}

// MARK: - Enumeración de procesos CoreAudio
struct AudioProc {
    let pid: pid_t
    let name: String
    let bundleID: String?
    var cat: String { detectCategory(name: name, bundleID: bundleID) }
}

func enumerateAudioProcesses() -> [AudioProc] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var objIDs = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objIDs) == noErr else { return [] }

    let ownPID = ProcessInfo.processInfo.processIdentifier
    var results: [AudioProc] = []

    for objID in objIDs {
        // PID
        var pidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0; var pidSz = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objID, &pidAddr, 0, nil, &pidSz, &pid) == noErr, pid > 0, pid != ownPID else { continue }

        // Bundle ID
        var bidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfBundle: CFString? = nil; var bidSz = UInt32(MemoryLayout<CFString?>.size)
        AudioObjectGetPropertyData(objID, &bidAddr, 0, nil, &bidSz, &cfBundle)
        let bundleID = cfBundle as String?

        // Nombre
        var name: String
        if let bid = bundleID, let last = bid.split(separator: ".").last {
            let s = String(last); name = s.prefix(1).uppercased() + s.dropFirst()
        } else {
            var buf = [CChar](repeating: 0, count: 256)
            proc_name(pid, &buf, UInt32(buf.count))
            name = String(cString: buf).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "PID-\(pid)" }
        }

        let skip = ["coreaudiod","audiotaphelper","audio ag","audiod","systemuiserver","windowserver"]
        guard !skip.contains(where: { name.lowercased().contains($0) }) else { continue }
        results.append(AudioProc(pid: pid, name: name, bundleID: bundleID))
    }
    return results
}

// MARK: - Almacén de niveles (thread-safe)
class LevelStore {
    private var lock = NSLock()
    private var data: [pid_t: (name: String, cat: String, rms: Double, db: Double, pct: Double)] = [:]

    func update(pid: pid_t, name: String, cat: String, rms: Double) {
        let db  = rms > 1e-8 ? 20.0 * log10(rms) : -96.0
        let pct = max(0.0, min(100.0, (db + 60.0) / 60.0 * 100.0))
        lock.lock(); data[pid] = (name, cat, rms, db, pct); lock.unlock()
    }

    func remove(pid: pid_t) {
        lock.lock(); data.removeValue(forKey: pid); lock.unlock()
    }

    func emitAll() {
        lock.lock(); let snapshot = data; lock.unlock()
        for (pid, v) in snapshot {
            let db = v.db.isFinite ? v.db : -96.0
            print("{\"pid\":\(pid),\"name\":\"\(v.name)\",\"rms\":\(String(format:"%.4f",v.rms)),\"db\":\(String(format:"%.1f",db)),\"pct\":\(String(format:"%.1f",v.pct)),\"cat\":\"\(v.cat)\"}")
        }
    }
}

// MARK: - Tap por proceso
class ProcessTap {
    let pid: pid_t; let name: String; let cat: String
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var engine: AVAudioEngine?
    private let store: LevelStore

    init?(proc: AudioProc, store: LevelStore) {
        self.pid = proc.pid; self.name = proc.name; self.cat = proc.cat; self.store = store
        guard start() else { return nil }
    }

    private func start() -> Bool {
        let desc = CATapDescription(stereoMixdownOfProcesses: [AudioObjectID(pid)])
        desc.name = "AudioAG-\(pid)"; desc.uuid = UUID(); desc.muteBehavior = CATapMuteBehavior.unmuted
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else {
            fputs("[ATH] Tap fail \(name)/\(pid)\n", stderr); return false
        }

        let eng = AVAudioEngine()
        var devID = tapID
        let setOK = AudioUnitSetProperty(
            eng.inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard setOK == noErr else {
            fputs("[ATH] SetDevice fail \(name): \(setOK)\n", stderr)
            AudioHardwareDestroyProcessTap(tapID); return false
        }

        let fmt = eng.inputNode.outputFormat(forBus: 0)
        eng.inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let self = self, let ch = buf.floatChannelData else { return }
            let frames = vDSP_Length(buf.frameLength)
            guard frames > 0 else { return }
            var sum: Float = 0
            let channels = Int(buf.format.channelCount)
            for c in 0..<max(1, channels) { var v: Float = 0; vDSP_measqv(ch[c], 1, &v, frames); sum += v }
            self.store.update(pid: self.pid, name: self.name, cat: self.cat, rms: Double(sqrt(sum / Float(max(1, channels)))))
        }

        do { try eng.start(); self.engine = eng; fputs("[ATH] Tapping \(name) (\(pid))\n", stderr); return true }
        catch { fputs("[ATH] Engine fail \(name): \(error)\n", stderr); eng.inputNode.removeTap(onBus: 0); AudioHardwareDestroyProcessTap(tapID); return false }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
        store.remove(pid: pid)
        fputs("[ATH] Stopped \(name)\n", stderr)
    }
    deinit { stop() }
}

// MARK: - Main
let store = LevelStore()
var taps: [pid_t: ProcessTap] = [:]

func refresh() {
    let procs = enumerateAudioProcesses()
    let newPIDs = Set(procs.map { $0.pid })
    for pid in Set(taps.keys).subtracting(newPIDs) { taps[pid]?.stop(); taps.removeValue(forKey: pid) }
    for proc in procs where !taps.keys.contains(proc.pid) {
        if let t = ProcessTap(proc: proc, store: store) { taps[proc.pid] = t }
    }
}

refresh()

let refreshQ = DispatchQueue(label: "ag.refresh")
let refreshSrc = DispatchSource.makeTimerSource(queue: refreshQ)
refreshSrc.schedule(deadline: .now() + 3, repeating: 3)
refreshSrc.setEventHandler { refresh() }
refreshSrc.resume()

let emitQ = DispatchQueue(label: "ag.emit")
let emitSrc = DispatchSource.makeTimerSource(queue: emitQ)
emitSrc.schedule(deadline: .now() + 0.033, repeating: 0.033)
emitSrc.setEventHandler { store.emitAll() }
emitSrc.resume()

signal(SIGTERM) { _ in taps.values.forEach { $0.stop() }; exit(0) }
signal(SIGINT)  { _ in taps.values.forEach { $0.stop() }; exit(0) }

fputs("[ATH] AudioTapHelper running...\n", stderr)
RunLoop.main.run()
