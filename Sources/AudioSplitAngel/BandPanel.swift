import SwiftUI

/// The five edges of the split: frequency and slope for each, and Reset.
struct EdgeRow: View {
    @EnvironmentObject var model: SplitModel

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<SplitConfig.edgeCount, id: \.self) { EdgeControl(edge: $0) }
            Spacer(minLength: 8)
            Button {
                model.resetToDefaults()
            } label: {
                Label("Reset to defaults", systemImage: "arrow.counterclockwise")
            }
            .help("Crossovers back to 20 Hz · 100 Hz · 1 kHz · 5 kHz · 20 kHz at 24 dB/oct, and every band back to 0 dB, unmuted. Devices and channels stay as they are.")
        }
    }
}

struct EdgeControl: View {
    @EnvironmentObject var model: SplitModel
    let edge: Int

    private var outer: Bool { SplitConfig.isOuter(edge) }

    var body: some View {
        let e = model.config.edges[edge]
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                // The colours of the band(s) this edge belongs to.
                if edge > 0 { Circle().fill(Palette.bands[edge - 1]).frame(width: 7, height: 7) }
                if edge < SplitConfig.bandCount { Circle().fill(Palette.bands[edge]).frame(width: 7, height: 7) }
                Text(SplitConfig.edgeNames[edge]).font(.caption.weight(.semibold)).foregroundColor(.secondary)
            }
            HStack(spacing: 6) {
                FrequencyField(hz: e.hz) { model.setEdge(edge, hz: $0) }
                    .frame(width: 76)
                    .disabled(outer && e.slope == 0)
                Picker("", selection: Binding(get: { e.slope }, set: { model.setSlope(edge, $0) })) {
                    ForEach(outer ? SplitConfig.outerSlopes : SplitConfig.crossoverSlopes, id: \.self) { s in
                        Text(s == 0 ? "Off" : "\(s) dB").tag(s)
                    }
                }
                .labelsHidden()
                .frame(width: 78)
                .help(slopeHelp)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.panel))
    }

    private var slopeHelp: String {
        if outer {
            return edge == 0
                ? "Low cut on the Low band: keeps sub-sonic rumble out of the bass speakers. Slope in dB per octave, or Off."
                : "High cut on the High band. Slope in dB per octave, or Off."
        }
        return "How sharply the two bands separate, in dB per octave. 24 is the standard (Linkwitz-Riley). 6 overlaps the most, 48 is the steepest. At 12 and 36 the upper band is polarity-inverted, as Linkwitz-Riley needs, so the speakers still add up evenly."
    }
}

/// A frequency you can type ("120", "1.2k"); Return or leaving the box applies it.
struct FrequencyField: View {
    let hz: Double
    let set: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(.system(size: 12).monospacedDigit())
            .focused($focused)
            .onAppear { text = hzText(hz) }
            .onChange(of: hz) { v in if !focused { text = hzText(v) } }
            .onChange(of: focused) { f in if !f { commit() } }
            .onSubmit { commit() }
            .help("Type a frequency: 80, 120 Hz, 1.2k, 2.5 kHz. Or drag its line in the display.")
    }

    private func commit() {
        if let v = parseHz(text) { set(v) }
        // Show what was actually applied (it may have been kept between its neighbours).
        DispatchQueue.main.async { text = hzText(hz) }
    }
}

/// One band: its range, level, mute and solo, meter, and where it plays.
struct BandCard: View {
    @EnvironmentObject var model: SplitModel
    @EnvironmentObject var meters: MeterStore
    let band: Int

    var body: some View {
        let c = model.config
        let b = c.bands[band]
        let color = Palette.bands[band]
        let range = c.range(of: band)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 16)
                Text(SplitConfig.bandNames[band]).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(rangeText(range, c)).font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                ToggleChip(title: "M", on: b.muted, color: .orange, help: "Mute this band") {
                    model.config.bands[band].muted.toggle()
                }
                ToggleChip(title: "S", on: b.solo, color: .yellow, help: "Solo: hear only the soloed bands") {
                    model.config.bands[band].solo.toggle()
                }
                Slider(value: $model.config.bands[band].gainDB, in: SplitConfig.gainRange)
                    .controlSize(.small)
                    .tint(color)
                Text(dbText(b.gainDB))
                    .font(.system(size: 11).monospacedDigit())
                    .frame(width: 56, alignment: .trailing)
                    .onTapGesture(count: 2) { model.config.bands[band].gainDB = 0 }
                    .help("Band level. Double-click for 0 dB.")
            }
            LevelMeter(levels: meters.bands[band], stereo: b.output.stereo, color: color)
                .frame(height: 10)
                .opacity(c.isAudible(band) ? 1 : 0.4)
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 6) {
                Text("OUTPUT").font(.caption2.weight(.semibold)).foregroundColor(.secondary)
                Spacer()
                HealthDot(health: model.outputHealth(band))
            }
            EndpointPicker(end: $model.config.bands[band].output, isInput: false, deviceWidth: 150)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.35)))
    }

    private func rangeText(_ r: (low: Double, high: Double), _ c: SplitConfig) -> String {
        let low = band == 0 && c.edges[0].slope == 0 ? "0 Hz" : hzText(r.low)
        let high = band == SplitConfig.bandCount - 1 && c.edges[SplitConfig.edgeCount - 1].slope == 0 ? "top" : hzText(r.high)
        return "\(low) – \(high)"
    }
}

struct ToggleChip: View {
    let title: String
    let on: Bool
    let color: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 20)
                .foregroundColor(on ? .black : .secondary)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? color : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
