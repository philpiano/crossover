import Foundation
import SplitCore

/// A mono channel or a stereo pair on one device.
struct Endpoint: Codable, Equatable {
    var deviceUID: String?
    /// Remembered so an unplugged device can still be shown by name.
    var deviceName: String?
    var firstChannel: Int = 0
    var stereo: Bool = true

    var width: Int { stereo ? 2 : 1 }
}

/// One edge of the split: a crossover between two bands, or an outer cut.
struct EdgeConfig: Codable, Equatable {
    var hz: Double
    /// dB per octave: 6, 12, 24, 36 or 48. Outer edges may also be 0 (off).
    var slope: Int
}

struct BandConfig: Codable, Equatable {
    var output = Endpoint()
    var gainDB: Double = 0
    var muted = false
    var solo = false
    var inverted = false
    /// false once the band has been deleted. Its range goes to the band above
    /// (or below, for the top band). Reset to defaults brings it back.
    var enabled = true

    init() {}

    // Every field optional when reading, so settings and presets saved before a
    // field existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        output = try c.decodeIfPresent(Endpoint.self, forKey: .output) ?? Endpoint()
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        inverted = try c.decodeIfPresent(Bool.self, forKey: .inverted) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// Everything a preset keeps: the input, the crossovers, and every band
/// (level, mute, solo, polarity, deleted or not, and its output). Not the
/// engine settings (sample rate, buffer, clock), which belong to the Mac.
struct SoundSettings: Codable, Equatable {
    var input = Endpoint()
    var edges = SplitConfig.defaultEdges
    var bands = Array(repeating: BandConfig(), count: SplitConfig.bandCount)
}

struct Preset: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var sound: SoundSettings
}

struct SplitConfig: Codable, Equatable {
    static let bandCount = Int(SC_BANDS)
    static let edgeCount = Int(SC_EDGES)

    static let bandNames = ["Low", "Mid", "Mid-High", "High"]
    static let crossoverSlopes = [6, 12, 24, 36, 48]
    static let outerSlopes = [0, 6, 12, 24, 36, 48]
    static let defaultEdges = [
        EdgeConfig(hz: 20, slope: 24),
        EdgeConfig(hz: 100, slope: 24),
        EdgeConfig(hz: 1000, slope: 24),
        EdgeConfig(hz: 5000, slope: 24),
        EdgeConfig(hz: 20000, slope: 24),
    ]
    static let minHz = Double(SC_MIN_HZ)
    static let maxHz = Double(SC_MAX_HZ)
    static let gainRange = -40.0...12.0

    var sound = SoundSettings()
    var sampleRate: Double = 48000
    /// 64 frames at 48 kHz is 1.3 ms per buffer.
    var bufferFrames: Int = 64
    /// nil = choose automatically (external hardware first).
    var clockDeviceUID: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sound = try c.decodeIfPresent(SoundSettings.self, forKey: .sound) ?? SoundSettings()
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 48000
        bufferFrames = try c.decodeIfPresent(Int.self, forKey: .bufferFrames) ?? 64
        clockDeviceUID = try c.decodeIfPresent(String.self, forKey: .clockDeviceUID)
    }

    // Shorthand: most of the app talks about these directly.
    var input: Endpoint {
        get { sound.input }
        set { sound.input = newValue }
    }
    var edges: [EdgeConfig] {
        get { sound.edges }
        set { sound.edges = newValue }
    }
    var bands: [BandConfig] {
        get { sound.bands }
        set { sound.bands = newValue }
    }

    static func isOuter(_ edge: Int) -> Bool { edge == 0 || edge == edgeCount - 1 }

    // MARK: Bands that remain

    /// Bit b set = band b exists.
    var enabledMask: UInt32 {
        bands.enumerated().reduce(0) { $0 | ($1.element.enabled ? 1 << UInt32($1.offset) : 0) }
    }

    var enabledBands: [Int] { bands.indices.filter { bands[$0].enabled } }

    /// Whether an edge is in use: the outer cuts always are; a crossover only
    /// while it separates two remaining bands.
    func isActive(edge k: Int) -> Bool {
        Self.isOuter(k) || sc_crossover_active(enabledMask, Int32(k))
    }

    var activeEdges: [Int] { (0..<Self.edgeCount).filter { isActive(edge: $0) } }

    /// The two bands on either side of a crossover (or the one band an outer cut
    /// belongs to), for naming and colouring it.
    func bandsAround(edge k: Int) -> [Int] {
        let e = enabledBands
        if k == 0 { return e.first.map { [$0] } ?? [] }
        if k == Self.edgeCount - 1 { return e.last.map { [$0] } ?? [] }
        guard let above = e.first(where: { $0 >= k }) else { return [k - 1] }
        return [k - 1, above]
    }

    func edgeName(_ k: Int) -> String {
        if k == 0 { return "Low cut" }
        if k == Self.edgeCount - 1 { return "High cut" }
        return bandsAround(edge: k).map { Self.bandNames[$0] }.joined(separator: " | ")
    }

    /// The frequency range a remaining band covers: from the active edge below
    /// it to the active edge above it.
    func range(of band: Int) -> (low: Double, high: Double) {
        // Band b sits between edges b and b+1. An inactive edge means the range
        // reaches on through removed bands to the next active one.
        var lo = band
        while lo > 0 && !isActive(edge: lo) { lo -= 1 }
        var hi = band + 1
        while hi < Self.edgeCount - 1 && !isActive(edge: hi) { hi += 1 }
        return (edges[lo].hz, edges[hi].hz)
    }

    /// Sets an edge's frequency, kept in order between its active neighbours (at
    /// least a twelfth of an octave apart) and within what the sample rate allows.
    mutating func setEdge(_ k: Int, hz: Double) {
        let gap = pow(2, 1.0 / 12)
        let top = min(Self.maxHz, 0.45 * sampleRate)
        let below = (0..<k).reversed().first { isActive(edge: $0) }
        let above = (k + 1..<Self.edgeCount).first { isActive(edge: $0) }
        let low = below.map { edges[$0].hz * gap } ?? Self.minHz
        let high = above.map { edges[$0].hz / gap } ?? top
        guard low <= high else { return }
        edges[k].hz = min(max(hz, low), high).rounded(toSignificant: 3)
    }

    /// Crossovers, slopes and every band's level, mute, solo and polarity back to
    /// the defaults, and deleted bands back. Devices and channels stay.
    mutating func resetToDefaults() {
        edges = Self.defaultEdges
        for b in bands.indices {
            bands[b].gainDB = 0
            bands[b].muted = false
            bands[b].solo = false
            bands[b].inverted = false
            bands[b].enabled = true
        }
    }

    /// Deletes a band. The last one left can't be deleted.
    mutating func deleteBand(_ b: Int) {
        guard bands[b].enabled, enabledBands.count > 1 else { return }
        bands[b].enabled = false
        bands[b].solo = false
    }

    /// A band is heard if it exists, isn't muted, and, when any band is soloed,
    /// is one of them.
    func isAudible(_ band: Int) -> Bool {
        let anySolo = bands.contains { $0.enabled && $0.solo }
        let b = bands[band]
        return b.enabled && !b.muted && (!anySolo || b.solo)
    }

    /// Writing a band back into the loopback channels the input reads from would
    /// feed the output into the next input: a runaway feedback loop.
    static func isFeedback(input: Endpoint, output: Endpoint, isVirtual: (String) -> Bool) -> Bool {
        guard let uid = input.deviceUID, uid == output.deviceUID, isVirtual(uid) else { return false }
        return input.firstChannel < output.firstChannel + output.width
            && output.firstChannel < input.firstChannel + input.width
    }
}

extension Double {
    func rounded(toSignificant digits: Int) -> Double {
        guard self > 0 else { return self }
        let scale = pow(10, Double(digits) - ceil(log10(self)))
        return (self * scale).rounded() / scale
    }
}

func linearGain(_ db: Double) -> Float {
    db <= SplitConfig.gainRange.lowerBound + 0.05 ? 0 : Float(pow(10, db / 20))
}

func dbText(_ db: Double) -> String {
    db <= SplitConfig.gainRange.lowerBound + 0.05 ? "−∞ dB" : String(format: "%+.1f dB", db)
}

/// Reads a typed level: "-6", "+3.5", "−4 dB", "-inf".
func parseDB(_ text: String) -> Double? {
    var t = text.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "−", with: "-")
    t = t.replacingOccurrences(of: "db", with: "").replacingOccurrences(of: ",", with: ".")
    if t == "-inf" || t == "-∞" || t == "inf" { return SplitConfig.gainRange.lowerBound }
    guard let v = Double(t), v.isFinite else { return nil }
    return min(max(v, SplitConfig.gainRange.lowerBound), SplitConfig.gainRange.upperBound)
}

/// "20 Hz", "35.5 Hz", "120 Hz", "1.25 kHz", "12.5 kHz".
func hzText(_ hz: Double) -> String {
    func trimmed(_ v: Double, _ digits: Int) -> String {
        var s = String(format: "%.\(digits)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
    return hz >= 1000 ? "\(trimmed(hz / 1000, hz >= 10000 ? 1 : 2)) kHz" : "\(trimmed(hz, hz >= 100 ? 0 : 1)) Hz"
}

/// Reads what someone types into a frequency box: "120", "1.2k", "1.2 kHz", "800hz".
func parseHz(_ text: String) -> Double? {
    var t = text.lowercased().replacingOccurrences(of: " ", with: "")
    t = t.replacingOccurrences(of: "hz", with: "")
    var scale = 1.0
    if t.hasSuffix("k") { scale = 1000; t.removeLast() }
    guard let v = Double(t.replacingOccurrences(of: ",", with: ".")), v > 0 else { return nil }
    return v * scale
}

// MARK: - Persistence

extension SplitConfig {
    private static let defaultsKey = "Crossover.Config.v1"

    static func load() -> SplitConfig? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              var c = try? JSONDecoder().decode(SplitConfig.self, from: data) else { return nil }
        c.sound.normalise()
        return c
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

extension SoundSettings {
    /// Makes anything loaded from disk safe to use: the right number of edges and
    /// bands, and at least one band left.
    mutating func normalise() {
        if edges.count != SplitConfig.edgeCount { edges = SplitConfig.defaultEdges }
        if bands.count != SplitConfig.bandCount {
            bands = Array((bands + Array(repeating: BandConfig(), count: SplitConfig.bandCount)).prefix(SplitConfig.bandCount))
        }
        if !bands.contains(where: \.enabled) { bands[0].enabled = true }
    }
}

enum PresetStore {
    private static let key = "Crossover.Presets.v1"

    static func load() -> [Preset] {
        guard let data = UserDefaults.standard.data(forKey: key),
              var list = try? JSONDecoder().decode([Preset].self, from: data) else { return [] }
        for i in list.indices { list[i].sound.normalise() }
        return list
    }

    static func save(_ presets: [Preset]) {
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: key) }
    }
}

// MARK: - First launch

extension SplitConfig {
    /// A starting point guessed from the devices present. Everything is editable.
    /// The input is a BlackHole loopback if there is one (the Mac's sound), else
    /// the first input. If there's an interface with at least 8 outputs, the four
    /// bands go to its pairs 1+2, 3+4, 5+6 and 7+8; otherwise outputs are left
    /// for you to choose, so nothing plays anywhere unexpected.
    static func makeDefault(devices: [AudioDeviceInfo]) -> SplitConfig {
        var config = SplitConfig()
        let blackHoles = devices.filter { $0.name.localizedCaseInsensitiveContains("blackhole") && $0.inputChannels >= 2 }
        let input = blackHoles.first { $0.name.localizedCaseInsensitiveContains("64") } ?? blackHoles.first
            ?? devices.first { $0.inputChannels > 0 }
        if let input {
            config.input = Endpoint(deviceUID: input.uid, deviceName: input.name, firstChannel: 0,
                                    stereo: input.inputChannels >= 2)
        }
        if let interface = devices.first(where: { $0.isExternalHardware && $0.outputChannels >= 8 }) {
            for b in config.bands.indices {
                config.bands[b].output = Endpoint(deviceUID: interface.uid, deviceName: interface.name,
                                                  firstChannel: b * 2, stereo: true)
            }
        }
        return config
    }
}
