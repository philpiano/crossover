import AppKit
import AVFoundation
import SwiftUI

/// Light, dark, or whatever the Mac is set to. Chosen in Settings (the gear).
enum Appearance: String, CaseIterable {
    case light, dark, system

    static let key = "Crossover.Appearance"
    static var current: Appearance { Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dark }

    func apply() {
        switch self {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
    }
}

/// The app's colours, for the light or dark look.
struct Palette {
    let dark: Bool

    init(_ scheme: ColorScheme) { dark = scheme == .dark }

    static let darkBands: [Color] = [
        Color(red: 1.00, green: 0.38, blue: 0.40), // low: coral
        Color(red: 1.00, green: 0.72, blue: 0.30), // mid: amber
        Color(red: 0.27, green: 0.85, blue: 0.56), // mid-high: green
        Color(red: 0.33, green: 0.65, blue: 1.00), // high: blue
    ]
    // The same hues, deeper, so they read on white.
    static let lightBands: [Color] = [
        Color(red: 0.91, green: 0.25, blue: 0.29),
        Color(red: 0.90, green: 0.55, blue: 0.04),
        Color(red: 0.10, green: 0.66, blue: 0.40),
        Color(red: 0.16, green: 0.46, blue: 0.93),
    ]

    var bands: [Color] { dark ? Self.darkBands : Self.lightBands }
    var window: Color { dark ? Color(red: 0.085, green: 0.09, blue: 0.105) : Color(red: 0.925, green: 0.93, blue: 0.945) }
    var panel: Color { dark ? Color(red: 0.125, green: 0.13, blue: 0.15) : .white }
    var graph: Color { dark ? Color(red: 0.055, green: 0.06, blue: 0.075) : Color(red: 0.985, green: 0.987, blue: 0.99) }
    /// Lines, text and marks drawn over the graph, used with opacity.
    var ink: Color { dark ? .white : .black }
    var line: Color { ink.opacity(0.08) }
}

/// The main window, top to bottom as the sound flows: the input, the split, the outputs.
struct ContentView: View {
    @EnvironmentObject var model: SplitModel
    @Environment(\.colorScheme) private var scheme

    /// Below this the window refuses to get narrower: every control still fits.
    static let minWidth: CGFloat = 1010

    var body: some View {
        let pal = Palette(scheme)
        VStack(spacing: 0) {
            TopBar()
            if model.micPermission == .denied || model.micPermission == .restricted {
                MicBanner()
            }
            CrossoverGraph()
                .frame(minHeight: 260)
                .padding(.horizontal, 16)
                .padding(.top, 14)
            EdgeRow()
                .padding(.horizontal, 16)
                .padding(.top, 12)
            HStack(spacing: 12) {
                ForEach(model.config.enabledBands, id: \.self) { BandCard(band: $0) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .frame(minWidth: Self.minWidth, minHeight: 680)
        .background(pal.window)
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let pal = Palette(scheme)
        HStack(spacing: 10) {
            LogoMark(size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Crossover").font(.system(size: 16, weight: .semibold))
                Text("One input, four speaker sets").font(.caption).foregroundColor(.secondary)
            }
            .fixedSize()
            Divider().frame(height: 30)
            Text("INPUT").font(.caption.weight(.semibold)).foregroundColor(.secondary).fixedSize()
            // The input takes whatever room the status leaves it.
            EndpointPicker(end: $model.config.input, isInput: true, deviceWidth: 140...420)
            HealthDot(health: model.inputHealth())
            LevelMeter(levels: meters.input, stereo: model.config.input.stereo, color: pal.ink.opacity(0.8))
                .frame(minWidth: 50, idealWidth: 100, maxWidth: 110)
                .frame(height: 12)
            Spacer(minLength: 8)
            EngineStatusView()
                .fixedSize()
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(pal.panel)
        .overlay(Rectangle().fill(pal.line).frame(height: 1), alignment: .bottom)
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
            .help("Appearance, sample rate, buffer size and clock")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                SettingsView().environmentObject(model).padding(16).frame(width: 360)
            }
        }
        .lineLimit(1)
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
    @AppStorage(Appearance.key) private var appearance = Appearance.dark.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Appearance").font(.headline)
                Spacer()
                Picker("", selection: $appearance) {
                    Image(systemName: "sun.max.fill").help("Light").tag(Appearance.light.rawValue)
                    Image(systemName: "moon.fill").help("Dark").tag(Appearance.dark.rawValue)
                    Image(systemName: "desktopcomputer").help("Same as the Mac").tag(Appearance.system.rawValue)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            Divider()
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
        .onChange(of: appearance) { Appearance(rawValue: $0)?.apply() }
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { g in
            let bars = stereo ? 2 : 1
            let gap: CGFloat = 2
            let h = (g.size.height - gap * CGFloat(bars - 1)) / CGFloat(bars)
            VStack(spacing: gap) {
                ForEach(0..<bars, id: \.self) { c in
                    let v = c < levels.count ? levels[c] : 0
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Palette(scheme).ink.opacity(0.08))
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

/// A device and its channels, for the input or one band's output. Both menus
/// stretch with the window, down to a minimum.
struct EndpointPicker: View {
    @EnvironmentObject var model: SplitModel
    @Binding var end: Endpoint
    let isInput: Bool
    var deviceWidth: ClosedRange<CGFloat> = 90...CGFloat.infinity

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
            .frame(minWidth: deviceWidth.lowerBound, maxWidth: deviceWidth.upperBound)
            .layoutPriority(1)

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
            .frame(minWidth: 64, idealWidth: 80, maxWidth: 88)
            .disabled(end.deviceUID == nil)
            .help(isInput ? "Input channels" : "Output channels")
        }
    }
}

// MARK: - Typable numbers

/// A small text box that edits a number in place: Return or clicking away
/// applies it, Escape cancels.
struct InlineEditor: View {
    @Binding var text: String
    let commit: () -> Void
    let cancel: () -> Void
    var fontSize: CGFloat = 11
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .font(.system(size: fontSize).monospacedDigit())
            .focused($focused)
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
            .onChange(of: focused) { if !$0 { commit() } }
    }
}

/// A level readout. Double-click to type a value; right-click to reset to 0 dB.
struct GainField: View {
    let db: Double
    let set: (Double) -> Void
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        Group {
            if editing {
                InlineEditor(text: $text, commit: commit, cancel: { editing = false })
            } else {
                Text(dbText(db))
                    .font(.system(size: 11).monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        text = String(format: "%.1f", db)
                        editing = true
                    }
                    .contextMenu { Button("Reset to 0 dB") { set(0) } }
                    .help("Double-click to type a level (−6, +3.5, −inf). Right-click to reset.")
            }
        }
        .frame(width: 60, height: 20)
    }

    private func commit() {
        guard editing else { return }
        editing = false
        if let v = parseDB(text) { set((v * 10).rounded() / 10) }
    }
}

/// A level slider: drag the knob (it doesn't jump), click the track to jump
/// there, double-click the knob for 0 dB. Snaps to 0 dB as you pass it.
struct GainSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let color: Color
    let set: (Double) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var grab: Double?
    @State private var startedOnKnob = false
    @State private var lastClick = Date.distantPast

    private let knob: CGFloat = 14

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let x = position(value, w)
            let zero = position(0, w)
            let pal = Palette(scheme)
            ZStack(alignment: .leading) {
                Capsule().fill(pal.ink.opacity(0.12)).frame(height: 4)
                Capsule().fill(color.opacity(0.9)).frame(width: max(x, 0), height: 4)
                Rectangle().fill(pal.ink.opacity(0.35)).frame(width: 1, height: 8).offset(x: zero - 0.5)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(color, lineWidth: 2))
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(x: x - knob / 2)
            }
            .frame(height: g.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if grab == nil {
                            startedOnKnob = abs(v.startLocation.x - x) <= knob
                            grab = startedOnKnob ? value - self.level(at: v.startLocation.x, w) : 0
                        }
                        let raw = self.level(at: v.location.x, w) + (grab ?? 0)
                        set(snap(raw))
                    }
                    .onEnded { v in
                        defer { grab = nil }
                        guard startedOnKnob, abs(v.translation.width) < 3 else { return }
                        // Two clicks on the knob close together: back to 0 dB.
                        if Date().timeIntervalSince(lastClick) < NSEvent.doubleClickInterval {
                            set(0)
                            lastClick = .distantPast
                        } else {
                            lastClick = Date()
                        }
                    }
            )
            .help("Band level. Double-click the knob for 0 dB.")
        }
        .frame(height: 20)
    }

    private func position(_ v: Double, _ w: CGFloat) -> CGFloat {
        let t = (min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
        return knob / 2 + CGFloat(t) * max(w - knob, 1)
    }

    private func level(at x: CGFloat, _ w: CGFloat) -> Double {
        let t = Double((x - knob / 2) / max(w - knob, 1))
        return range.lowerBound + min(max(t, 0), 1) * (range.upperBound - range.lowerBound)
    }

    private func snap(_ v: Double) -> Double {
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        return abs(clamped) < 0.4 ? 0 : (clamped * 10).rounded() / 10
    }
}
