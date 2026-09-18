import AppKit
import AVFoundation
import SwiftUI

enum Palette {
    static let bands: [Color] = [
        Color(red: 1.00, green: 0.38, blue: 0.40), // low: coral
        Color(red: 1.00, green: 0.72, blue: 0.30), // mid: amber
        Color(red: 0.27, green: 0.85, blue: 0.56), // mid-high: green
        Color(red: 0.33, green: 0.65, blue: 1.00), // high: blue
    ]
    static let window = Color(red: 0.085, green: 0.09, blue: 0.105)
    static let panel = Color(red: 0.125, green: 0.13, blue: 0.15)
    static let graph = Color(red: 0.055, green: 0.06, blue: 0.075)
    static let line = Color.white.opacity(0.08)
}

/// The main window, top to bottom as the sound flows: the input, the split, the outputs.
struct ContentView: View {
    @EnvironmentObject var model: SplitModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            if model.micPermission == .denied || model.micPermission == .restricted {
                MicBanner()
            }
            CrossoverGraph()
                .frame(minHeight: 300)
                .padding(.horizontal, 16)
                .padding(.top, 14)
            EdgeRow()
                .padding(.horizontal, 16)
                .padding(.top, 12)
            HStack(spacing: 12) {
                ForEach(0..<SplitConfig.bandCount, id: \.self) { BandCard(band: $0) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 1040, minHeight: 720)
        .background(Palette.window)
        .preferredColorScheme(.dark)
    }
}

struct LogoMark: View {
    var size: CGFloat
    private static let image = NSImage(named: "Logo")

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "waveform.circle.fill")
                .resizable()
                .foregroundColor(.orange)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var model: SplitModel
    @EnvironmentObject var meters: MeterStore

    var body: some View {
        HStack(spacing: 14) {
            LogoMark(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Audio Split Angel").font(.system(size: 16, weight: .semibold))
                Text("One input, four speaker sets").font(.caption).foregroundColor(.secondary)
            }
            .fixedSize()
            Divider().frame(height: 30).padding(.horizontal, 4)
            Text("INPUT").font(.caption.weight(.semibold)).foregroundColor(.secondary)
            EndpointPicker(end: $model.config.input, isInput: true)
            HealthDot(health: model.inputHealth())
            LevelMeter(levels: meters.input, stereo: model.config.input.stereo, color: .white.opacity(0.85))
                .frame(width: 110, height: 12)
            Spacer(minLength: 12)
            EngineStatusView()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.panel)
        .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)
    }
}

struct MicBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.slash.fill").foregroundColor(.orange)
            Text("Microphone access is off, so the input is silent. macOS counts every audio input, loopbacks too, as a microphone.")
                .font(.callout)
            Spacer()
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
    }
}

struct EngineStatusView: View {
    @EnvironmentObject var model: SplitModel
    @EnvironmentObject var meters: MeterStore
    @State private var showSettings = false

    var body: some View {
        let s = model.status
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(Self.color(s.state)).frame(width: 9, height: 9)
                Text(s.state == .running ? "Running" : s.state.rawValue.capitalized).fontWeight(.semibold)
            }
            .help(s.message)
            if !s.warnings.isEmpty { StatusListButton(kind: .warning, items: s.warnings) }
            if !s.notes.isEmpty { StatusListButton(kind: .note, items: s.notes) }
            if s.state == .running {
                Text(String(format: "≈ %.1f ms", s.inputLatencyMs + s.outputLatencyMs))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .help(String(format: "Delay from input to speakers: %.1f ms in + %.1f ms out, at %d frames and %.0f Hz. The crossover itself adds none.",
                                 s.inputLatencyMs, s.outputLatencyMs, s.bufferFrames, s.sampleRate))
            } else {
                Text(s.message).foregroundColor(.secondary).lineLimit(1)
            }
            if model.overloads > 0 {
                CounterBadge(icon: "bolt.trianglebadge.exclamationmark", title: "Dropouts", count: model.overloads, color: .orange,
                             help: "Times the Mac couldn't prepare the audio in time, so a tiny click got through. If it keeps climbing, raise the buffer size in Settings. Click to clear.") {
                    model.resetOverloads()
                }
            }
            if meters.clips > 0 {
                CounterBadge(icon: "waveform.badge.exclamationmark", title: "Clipped", count: Int(clamping: meters.clips), color: .red,
                             help: "Times an output went over full scale and the safety stage caught it. Turn the boosted band down a little. Click to clear.") {
                    meters.resetClips()
                }
            }
            Button {
                model.resetOverloads()
                meters.resetClips()
                model.engine.restart()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Restart the audio engine and clear the counters")
            Button { showSettings.toggle() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Sample rate, buffer size and clock")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                SettingsView().environmentObject(model).padding(16).frame(width: 360)
            }
        }
    }

    static func color(_ state: EngineStatus.State) -> Color {
        switch state {
        case .running: return .green
        case .starting, .waiting: return .orange
        case .error: return .red
        case .stopped: return .gray
        }
    }
}

/// A named count of something that went wrong since it was last cleared. Click to clear.
struct CounterBadge: View {
    let icon: String
    let title: String
    let count: Int
    let color: Color
    let help: String
    let reset: () -> Void

    var body: some View {
        Button(action: reset) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text("\(title) \(count)").monospacedDigit()
            }
            .foregroundColor(color)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// ⚠ or ⓘ next to the status; click to read the list.
struct StatusListButton: View {
    enum Kind { case warning, note }
    let kind: Kind
    let items: [String]
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: kind == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundColor(kind == .warning ? .orange : .secondary)
        }
        .buttonStyle(.borderless)
        .help(items.joined(separator: "\n"))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.self) { Text("• \($0)").fixedSize(horizontal: false, vertical: true) }
            }
            .padding(14)
            .frame(width: 340)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: SplitModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Engine").font(.headline)
            Picker("Sample rate", selection: $model.config.sampleRate) {
                ForEach([44100.0, 48000.0, 88200.0, 96000.0], id: \.self) { Text("\(Int($0)) Hz").tag($0) }
            }
            Picker("Buffer size", selection: $model.config.bufferFrames) {
                ForEach([32, 64, 128, 256, 512], id: \.self) { n in
                    Text("\(n) frames (\(String(format: "%.1f", Double(n) / model.config.sampleRate * 1000)) ms)").tag(n)
                }
            }
            Picker("Clock", selection: $model.config.clockDeviceUID) {
                Text("Automatic").tag(String?.none)
                ForEach(model.status.devicesInUse, id: \.self) { name in
                    if let d = model.devices.first(where: { $0.name == name }) { Text(d.name).tag(Optional(d.uid)) }
                }
            }
            Text("Smaller buffers mean less delay. If you hear clicks or the Dropouts counter climbs, go up a size. The crossover adds no delay of its own. With several devices, the clock device keeps time and the others follow it.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Shared controls

struct HealthDot: View {
    let health: EndpointHealth

    var body: some View {
        Circle().fill(health.color).frame(width: 8, height: 8).help(health.help)
    }
}

/// Horizontal peak meter, one bar per channel, green to yellow to red.
struct LevelMeter: View {
    let levels: [Float]
    let stereo: Bool
    var color: Color = .green

    var body: some View {
        GeometryReader { g in
            let bars = stereo ? 2 : 1
            let gap: CGFloat = 2
            let h = (g.size.height - gap * CGFloat(bars - 1)) / CGFloat(bars)
            VStack(spacing: gap) {
                ForEach(0..<bars, id: \.self) { c in
                    let v = c < levels.count ? levels[c] : 0
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.07))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(LinearGradient(colors: [color.opacity(0.75), color, .yellow, .red],
                                                 startPoint: .leading, endPoint: .trailing))
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: g.size.width * Self.fraction(v))
                            }
                    }
                    .frame(height: h)
                }
            }
        }
    }

    /// -60 dBFS to 0 dBFS across the bar.
    static func fraction(_ peak: Float) -> CGFloat {
        guard peak > 0 else { return 0 }
        let db = 20 * log10(Double(peak))
        return CGFloat(min(max((db + 60) / 60, 0), 1))
    }
}

/// A device and its channels, for the input or one band's output.
struct EndpointPicker: View {
    @EnvironmentObject var model: SplitModel
    @Binding var end: Endpoint
    let isInput: Bool
    var deviceWidth: CGFloat = 210

    private var devices: [AudioDeviceInfo] { isInput ? model.inputDevices : model.outputDevices }
    private func channels(_ d: AudioDeviceInfo) -> Int { isInput ? d.inputChannels : d.outputChannels }

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(
                get: { end.deviceUID ?? "" },
                set: { uid in model.choose(uid.isEmpty ? nil : uid, for: &end) { isInput ? $0.inputChannels : $0.outputChannels } }
            )) {
                Text("None").tag("")
                ForEach(devices) { d in Text(d.name).tag(d.uid) }
                if let uid = end.deviceUID, !devices.contains(where: { $0.uid == uid }) {
                    Text("\(end.deviceName ?? "Device") (not connected)").tag(uid)
                }
            }
            .labelsHidden()
            .frame(width: deviceWidth)

            let count = model.device(end.deviceUID).map(channels) ?? max(end.firstChannel + end.width, 2)
            Picker("", selection: Binding(
                get: { (end.stereo ? "s" : "m") + String(end.firstChannel) },
                set: { tag in
                    end.stereo = tag.hasPrefix("s")
                    end.firstChannel = Int(tag.dropFirst()) ?? 0
                }
            )) {
                // Tags double as IDs, so stereo "s0" and mono "m0" never collide.
                if count >= 2 {
                    Section("Stereo") {
                        ForEach(stride(from: 0, to: count - 1, by: 2).map { "s\($0)" }, id: \.self) { tag in
                            let c = Int(tag.dropFirst()) ?? 0
                            Text("\(c + 1)+\(c + 2)").tag(tag)
                        }
                    }
                }
                Section("Mono") {
                    ForEach((0..<count).map { "m\($0)" }, id: \.self) { tag in
                        Text("\((Int(tag.dropFirst()) ?? 0) + 1)").tag(tag)
                    }
                }
            }
            .labelsHidden()
            .frame(width: 78)
            .disabled(end.deviceUID == nil)
            .help(isInput ? "Input channels" : "Output channels")
        }
    }
}
