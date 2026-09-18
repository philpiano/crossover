import Accelerate
import AppKit
import AVFoundation
import SplitCore
import SwiftUI

enum EndpointHealth {
    case unassigned, offline, badChannels, feedback, ok

    var color: Color {
        switch self {
        case .ok: return .green
        case .unassigned: return .gray
        case .offline: return .orange
        case .badChannels, .feedback: return .red
        }
    }

    var help: String {
        switch self {
        case .ok: return "Connected"
        case .unassigned: return "No device chosen"
        case .offline: return "Device not connected. It will reconnect by itself."
        case .badChannels: return "That device doesn't have these channels"
        case .feedback: return "Silenced: this would play back into the loopback channels the input reads from"
        }
    }
}

/// The app's state: the saved config, the device list, and the engine.
final class SplitModel: ObservableObject {
    static weak var current: SplitModel?

    @Published var config: SplitConfig {
        didSet {
            guard config != oldValue else { return }
            engine.update(config: config)
            scheduleSave()
            if !restoring { noteChange(from: oldValue) }
        }
    }
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var presets: [Preset] = []
    /// The preset last loaded or saved, if any.
    @Published private(set) var currentPreset: String?
    @Published private(set) var devices: [AudioDeviceInfo] = []
    @Published private(set) var status = EngineStatus()
    @Published private(set) var overloads = 0
    @Published private(set) var micPermission: AVAuthorizationStatus = .notDetermined

    let engine = EngineController()
    let meters: MeterStore
    let spectrum: SpectrumStore
    private var saveItem: DispatchWorkItem?
    private var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    /// false for snapshots and checks: nothing is saved.
    private let live: Bool

    /// `live: false` builds the model for a UI snapshot: no audio, no permission
    /// prompt, nothing saved.
    init(live: Bool = true) {
        self.live = live
        meters = MeterStore(core: engine.core, live: live)
        spectrum = SpectrumStore(core: engine.core, live: live)
        let found = AudioDeviceInfo.all()
        devices = found
        config = SplitConfig.load() ?? SplitConfig.makeDefault(devices: found)
        presets = live ? PresetStore.load() : []
        currentPreset = UserDefaults.standard.string(forKey: Self.currentPresetKey).flatMap { name in
            presets.contains { $0.name == name } ? name : nil
        }
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio) // reading it never prompts
        guard live else { return }
        SplitModel.current = self

        engine.onStatus = { [weak self] in
            self?.status = $0
            self?.spectrum.setSampleRate($0.sampleRate)
        }
        engine.onOverload = { [weak self] in self?.overloads += 1 }
        engine.onSystemDevicesChanged = { [weak self] in self?.refreshDevices() }

        // Audio must never be throttled by App Nap, even with the window hidden.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Splitting live audio")

        // USB devices re-enumerate after sleep; rebuild once they're back.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.restart(after: 2)
        })

        config.save()
        engine.update(config: config)
        engine.start()
        checkMicPermission()
    }

    func shutdown() {
        saveItem?.perform()
        config.save()
        engine.shutdown()
        meters.stop()
        spectrum.stop()
    }

    func resetOverloads() { overloads = 0 }

    /// Snapshots only: show a running engine and stand-in devices. Nothing starts.
    func showForSnapshot(_ status: EngineStatus, devices: [AudioDeviceInfo], presets: [Preset] = [], current: String? = nil) {
        self.status = status
        self.devices = devices
        self.presets = presets
        currentPreset = current
        micPermission = .authorized
    }

    // MARK: - Devices

    func refreshDevices() {
        devices = AudioDeviceInfo.all()
    }

    func device(_ uid: String?) -> AudioDeviceInfo? {
        guard let uid else { return nil }
        return devices.first { $0.uid == uid }
    }

    var inputDevices: [AudioDeviceInfo] { devices.filter { $0.inputChannels > 0 } }
    var outputDevices: [AudioDeviceInfo] { devices.filter { $0.outputChannels > 0 } }

    func inputHealth() -> EndpointHealth {
        health(config.input, channels: \.inputChannels)
    }

    func outputHealth(_ band: Int) -> EndpointHealth {
        let end = config.bands[band].output
        let h = health(end, channels: \.outputChannels)
        guard h == .ok else { return h }
        let feedback = SplitConfig.isFeedback(input: config.input, output: end) { self.device($0)?.isVirtual ?? false }
        return feedback ? .feedback : .ok
    }

    private func health(_ end: Endpoint, channels: (AudioDeviceInfo) -> Int) -> EndpointHealth {
        guard let uid = end.deviceUID else { return .unassigned }
        guard let d = device(uid) else { return .offline }
        return end.firstChannel + end.width <= channels(d) ? .ok : .badChannels
    }

    /// Picks a device, keeping the channel choice if the device has it, else its first pair.
    func choose(_ uid: String?, for end: inout Endpoint, channels: (AudioDeviceInfo) -> Int) {
        guard let uid, let d = device(uid) else {
            end = Endpoint()
            return
        }
        let count = channels(d)
        end.deviceUID = uid
        end.deviceName = d.name
        if end.firstChannel + end.width > count {
            end.firstChannel = 0
            end.stereo = count >= 2
        }
    }

    // MARK: - Edits

    func setEdge(_ k: Int, hz: Double) { config.setEdge(k, hz: hz) }

    func setSlope(_ k: Int, _ slope: Int) { config.edges[k].slope = slope }

    func resetToDefaults() { config.resetToDefaults() }

    func deleteBand(_ b: Int) { config.deleteBand(b) }

    // MARK: - Undo

    // Undo works on whole snapshots of the config. Changes that follow each
    // other closely (a drag, a stream of typing) settle into one step.
    private var undoStack: [SplitConfig] = []
    private var redoStack: [SplitConfig] = []
    private var pendingBase: SplitConfig?
    private var settleItem: DispatchWorkItem?
    private var restoring = false
    private static let undoLimit = 200

    private func noteChange(from old: SplitConfig) {
        if pendingBase == nil { pendingBase = old }
        settleItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.settle() }
        settleItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
        if !canUndo { canUndo = true }
    }

    private func settle() {
        settleItem?.cancel()
        settleItem = nil
        if let base = pendingBase, base != config {
            undoStack.append(base)
            if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        pendingBase = nil
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func undo() {
        settle()
        guard let previous = undoStack.popLast() else { return NSSound.beep() }
        redoStack.append(config)
        restore(previous)
    }

    func redo() {
        settle()
        guard let next = redoStack.popLast() else { return NSSound.beep() }
        undoStack.append(config)
        restore(next)
    }

    private func restore(_ c: SplitConfig) {
        restoring = true
        config = c
        restoring = false
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: - Presets

    private static let currentPresetKey = "Crossover.CurrentPreset"

    /// Whether the sound differs from the current preset as saved.
    var presetEdited: Bool {
        guard let name = currentPreset, let p = presets.first(where: { $0.name == name }) else { return false }
        return p.sound != config.sound
    }

    func nextPresetName() -> String {
        var n = presets.count + 1
        while presets.contains(where: { $0.name == "Preset \(n)" }) { n += 1 }
        return "Preset \(n)"
    }

    /// Saves the current sound under a name, replacing a preset of that name.
    func savePreset(named raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = Preset(name: name, sound: config.sound)
        if let i = presets.firstIndex(where: { $0.name == name }) { presets[i] = preset } else { presets.append(preset) }
        setCurrentPreset(name)
        if live { PresetStore.save(presets) }
    }

    func loadPreset(_ name: String) {
        guard let p = presets.first(where: { $0.name == name }) else { return }
        config.sound = p.sound
        setCurrentPreset(name)
    }

    func deletePreset(_ name: String) {
        presets.removeAll { $0.name == name }
        if currentPreset == name { setCurrentPreset(nil) }
        if live { PresetStore.save(presets) }
    }

    private func setCurrentPreset(_ name: String?) {
        currentPreset = name
        if live { UserDefaults.standard.set(name, forKey: Self.currentPresetKey) }
    }

    // MARK: - Permission

    func checkMicPermission() {
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micPermission == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async {
                self.micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
                self.engine.restart(after: 0.2)
            }
        }
    }

    // MARK: - Saving

    private func scheduleSave() {
        guard live else { return }
        saveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.config.save() }
        saveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}

/// Meter levels, polled from the engine at 30 Hz. Kept separate from SplitModel
/// so only the meters redraw 30 times a second, not the whole window.
final class MeterStore: ObservableObject {
    @Published private(set) var input: [Float] = [0, 0]
    @Published private(set) var bands = Array(repeating: [Float](repeating: 0, count: 2), count: SplitConfig.bandCount)
    @Published private(set) var clips: UInt64 = 0

    private let core: OpaquePointer
    private var timer: Timer?
    private var clipBaseline: UInt64 = 0

    init(core: OpaquePointer, live: Bool) {
        self.core = core
        guard live else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate() }

    /// The engine's clip count only ever grows; "reset" counts from here on.
    func resetClips() {
        clipBaseline = sc_engine_clip_count(core)
        clips = 0
    }

    /// Snapshots only: fixed levels.
    func show(input: [Float], bands: [[Float]]) {
        self.input = input
        self.bands = bands
    }

    private func tick() {
        // Fast attack, ~300 ms release.
        let release: Float = 0.82
        var newIn = input, newBands = bands
        for c in 0..<2 {
            newIn[c] = max(sc_engine_take_input_peak(core, Int32(c)), newIn[c] * release)
            for b in 0..<newBands.count {
                newBands[b][c] = max(sc_engine_take_band_peak(core, Int32(b), Int32(c)), newBands[b][c] * release)
            }
        }
        if newIn != input { input = newIn }
        if newBands != bands { bands = newBands }
        let total = sc_engine_clip_count(core)
        let c = total >= clipBaseline ? total - clipBaseline : 0
        if c != clips { clips = c }
    }
}

/// The spectrum of the input, for the analyser behind the crossover curves.
///
/// Reads the engine's most recent 8192 input samples 30 times a second, windows
/// them, and takes an FFT. The result is resampled onto `pointCount` points
/// spaced evenly in octaves from 15 Hz to 22 kHz, tilted +3 dB per octave around
/// 1 kHz so pink noise (and most music) reads level, and smoothed like a DAW
/// analyser: it jumps up at once and falls back gently.
final class SpectrumStore: ObservableObject {
    static let pointCount = 240
    static let lowHz = 15.0
    static let highHz = 22000.0
    /// The analyser's floor and ceiling, in dBFS after the tilt.
    static let floorDB: Float = -90
    static let ceilingDB: Float = 0

    /// dB per display point, `floorDB` when there is nothing there.
    @Published private(set) var levels = [Float](repeating: SpectrumStore.floorDB, count: SpectrumStore.pointCount)

    private let core: OpaquePointer
    private var timer: Timer?
    private let log2n: vDSP_Length = 13
    private var n: Int { 1 << Int(log2n) }
    private let setup: FFTSetup?
    private var window: [Float]
    private var samples: [Float]
    private var lastWritten: UInt64 = 0
    private var sampleRate: Double = 48000
    private var quietFrames = 0

    init(core: OpaquePointer, live: Bool) {
        self.core = core
        setup = vDSP_create_fftsetup(13, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: 1 << 13)
        samples = [Float](repeating: 0, count: 1 << 13)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM)) // peak 1, coherent gain 0.5
        guard live else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    func stop() { timer?.invalidate() }

    func setSampleRate(_ rate: Double) {
        if rate > 0 { sampleRate = rate }
    }

    /// Snapshots only: show the spectrum of a given signal.
    func show(signal: [Float], sampleRate: Double) {
        self.sampleRate = sampleRate
        let count = min(signal.count, n)
        samples = [Float](repeating: 0, count: n - count) + signal.suffix(count)
        levels = analyse()
    }

    private func tick() {
        let written = sc_engine_read_scope(core, &samples, UInt32(n))
        if written == lastWritten {
            // Nothing new (stopped, or no input): let the display fall to the floor.
            quietFrames += 1
            if quietFrames > 2 { fall(toward: [Float](repeating: Self.floorDB, count: Self.pointCount)) }
            return
        }
        quietFrames = 0
        lastWritten = written
        fall(toward: analyse())
    }

    /// Up at once, down at about 30 dB a second.
    private func fall(toward target: [Float]) {
        let drop: Float = 1.0
        var next = levels
        for i in next.indices { next[i] = max(target[i], next[i] - drop) }
        if next != levels { levels = next }
    }

    private func analyse() -> [Float] {
        guard let setup else { return levels }
        let half = n / 2
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        // A full-scale sine, Hann-windowed (coherent gain 0.5), is n/4 in a true
        // DFT; zrip doubles that to n/2, so its power is n²/4. That reads 0 dBFS.
        let fullScale = Float(n) * Float(n) / 4
        let binHz = sampleRate / Double(n)
        var out = [Float](repeating: Self.floorDB, count: Self.pointCount)
        let octaves = log2(Self.highHz / Self.lowHz)
        for i in 0..<Self.pointCount {
            let f0 = Self.lowHz * pow(2, octaves * (Double(i) - 0.5) / Double(Self.pointCount - 1))
            let f1 = Self.lowHz * pow(2, octaves * (Double(i) + 0.5) / Double(Self.pointCount - 1))
            let fc = sqrt(f0 * f1)
            var p: Float = 0
            let b0 = Int((f0 / binHz).rounded(.down)), b1 = Int((f1 / binHz).rounded(.up))
            if b1 - b0 <= 1 {
                // Narrower than a bin (the bass): interpolate between the two nearest.
                let x = fc / binHz, j = Int(x), t = Float(x - Double(j))
                if j + 1 < half, j >= 1 { p = power[j] * (1 - t) + power[j + 1] * t }
            } else {
                // Wider (the treble): the loudest bin in the range, as analysers show peaks.
                for j in max(b0, 1)..<min(b1, half) { p = max(p, power[j]) }
            }
            let tilt = Float(3 * log2(fc / 1000))
            let db = 10 * log10(max(p / fullScale, 1e-12)) + tilt
            out[i] = min(max(db, Self.floorDB), Self.ceilingDB + 12)
        }
        return out
    }
}
