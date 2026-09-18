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

    var channelText: String {
        stereo ? "\(firstChannel + 1)+\(firstChannel + 2)" : "\(firstChannel + 1)"
    }
}

/// One edge of the split: a crossover between two bands, or an outer band limit.
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
}

struct SplitConfig: Codable, Equatable {
    static let bandCount = Int(SC_BANDS)
    static let edgeCount = Int(SC_EDGES)

    static let bandNames = ["Low", "Mid", "Mid-High", "High"]
    static let edgeNames = ["Low cut", "Low | Mid", "Mid | Mid-High", "Mid-High | High", "High cut"]
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

    var input = Endpoint()
    var edges = SplitConfig.defaultEdges
    var bands = Array(repeating: BandConfig(), count: SplitConfig.bandCount)
    var sampleRate: Double = 48000
    /// 64 frames at 48 kHz is 1.3 ms per buffer.
    var bufferFrames: Int = 64
    /// nil = choose automatically (external hardware first).
    var clockDeviceUID: String?

    static func isOuter(_ edge: Int) -> Bool { edge == 0 || edge == edgeCount - 1 }

    /// The frequency range a band covers: from its lower edge to its upper edge.
    func range(of band: Int) -> (low: Double, high: Double) {
        (edges[band].hz, edges[band + 1].hz)
    }

    /// Sets an edge's frequency, kept in order between its neighbours (at least a
    /// twelfth of an octave apart) and within what the sample rate allows.
    mutating func setEdge(_ k: Int, hz: Double) {
        let gap = pow(2, 1.0 / 12)
        let top = min(Self.maxHz, 0.45 * sampleRate)
        let low = k > 0 ? edges[k - 1].hz * gap : Self.minHz
        let high = k < Self.edgeCount - 1 ? edges[k + 1].hz / gap : top
        guard low <= high else { return }
        edges[k].hz = min(max(hz, low), high).rounded(toSignificant: 3)
    }

    /// Crossovers, slopes and band levels back to the defaults. Devices and
    /// channels stay as they are.
    mutating func resetToDefaults() {
        edges = Self.defaultEdges
        for b in bands.indices {
            bands[b].gainDB = 0
            bands[b].muted = false
            bands[b].solo = false
        }
    }

    /// A band is heard if it isn't muted and, when any band is soloed, it's one of them.
    func isAudible(_ band: Int) -> Bool {
        let anySolo = bands.contains { $0.solo }
        return !bands[band].muted && (!anySolo || bands[band].solo)
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
    private static let defaultsKey = "AudioSplitAngel.Config.v1"

    static func load() -> SplitConfig? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let c = try? JSONDecoder().decode(SplitConfig.self, from: data),
              c.edges.count == edgeCount, c.bands.count == bandCount else { return nil }
        return c
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
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
