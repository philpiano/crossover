import SwiftUI

/// The edges of the split (frequency and slope for each), presets, and Reset.
struct EdgeRow: View {
    @EnvironmentObject var model: SplitModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(model.config.activeEdges, id: \.self) { EdgeControl(edge: $0) }
            VStack(spacing: 6) {
                PresetMenu()
                Button {
                    model.resetToDefaults()
                } label: {
                    Label("Reset to defaults", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .help("Crossovers back to 20 Hz · 100 Hz · 1 kHz · 5 kHz · 20 kHz at 24 dB/oct, every band back (including deleted ones) at 0 dB, unmuted, normal polarity. Devices and channels stay as they are.")
            }
            .frame(width: 150)
        }
    }
}

/// Presets: save the whole sound, recall it, delete it.
struct PresetMenu: View {
    @EnvironmentObject var model: SplitModel
    @State private var naming = false
    @State private var name = ""
    @State private var confirmDelete = false

    var body: some View {
        Menu {
            Button("Save this Preset…") {
                name = model.currentPreset ?? model.nextPresetName()
                naming = true
            }
            if let current = model.currentPreset, model.presetEdited {
                Button("Update “\(current)”") { model.savePreset(named: current) }
            }
            Button("Delete this Preset") { confirmDelete = true }
                .disabled(model.currentPreset == nil)
            Divider()
            if model.presets.isEmpty {
                Text("No presets yet")
            }
            ForEach(model.presets) { p in
                Button { model.loadPreset(p.name) } label: {
                    if p.name == model.currentPreset { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
        } label: {
            Label(label, systemImage: "square.stack.3d.up")
        }
        .help("Save everything you hear (input, crossovers, bands and their outputs) as a preset, and come back to it later.")
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { model.savePreset(named: name) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A preset with the same name is replaced.")
        }
        .alert("Delete “\(model.currentPreset ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { if let c = model.currentPreset { model.deletePreset(c) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The sound stays as it is; only the saved preset goes.")
        }
    }

    private var label: String {
        guard let c = model.currentPreset else { return "Presets" }
        return model.presetEdited ? "\(c) (edited)" : c
    }
}

struct EdgeControl: View {
    @EnvironmentObject var model: SplitModel
    @Environment(\.colorScheme) private var scheme
    let edge: Int

    private var outer: Bool { SplitConfig.isOuter(edge) }

    var body: some View {
        let e = model.config.edges[edge]
        let pal = Palette(scheme)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                // The colours of the band(s) this edge belongs to.
                ForEach(model.config.bandsAround(edge: edge), id: \.self) { b in
                    Circle().fill(pal.bands[b]).frame(width: 7, height: 7)
                }
                Text(model.config.edgeName(edge))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 4) {
                FrequencyField(hz: e.hz) { model.setEdge(edge, hz: $0) }
                    .frame(minWidth: 60, idealWidth: 76, maxWidth: 90)
                    .disabled(outer && e.slope == 0)
                Picker("", selection: Binding(get: { e.slope }, set: { model.setSlope(edge, $0) })) {
                    ForEach(outer ? SplitConfig.outerSlopes : SplitConfig.crossoverSlopes, id: \.self) { s in
                        Text(s == 0 ? "Off" : "\(s) dB").tag(s)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 76, idealWidth: 80, maxWidth: 90)
                .help(slopeHelp)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(pal.panel))
    }

    private var slopeHelp: String {
        if outer {
            return edge == 0
                ? "Low cut on the input: keeps sub-sonic rumble out of the bass speakers. Slope in dB per octave, or Off."
                : "High cut on the input. Slope in dB per octave, or Off."
        }
        return "How sharply the two bands separate, in dB per octave. 24 is the standard (Linkwitz-Riley). 6 overlaps the most; 96 is the steepest, close to a brick wall. At 12 and 36 the upper band is polarity-inverted, as Linkwitz-Riley needs, so the speakers still add up evenly."
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

/// One band: its range, level, mute, solo and polarity, meter, and where it plays.
struct BandCard: View {
    @EnvironmentObject var model: SplitModel
    @EnvironmentObject var meters: MeterStore
    @Environment(\.colorScheme) private var scheme
    let band: Int

    var body: some View {
        let c = model.config
        let b = c.bands[band]
        let pal = Palette(scheme)
        let color = pal.bands[band]
        let range = c.range(of: band)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 16)
                Text(SplitConfig.bandNames[band]).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(rangeText(range, c))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Menu {
                    Button("Delete Band") { model.deleteBand(band) }
                        .disabled(c.enabledBands.count <= 1)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Delete this band: its range goes to the band above (or below, for the top one). Reset to defaults, or Undo, brings it back.")
            }
            HStack(spacing: 6) {
                ToggleChip(title: "M", on: b.muted, color: .orange, help: "Mute this band") {
                    model.config.bands[band].muted.toggle()
                }
                ToggleChip(title: "S", on: b.solo, color: .yellow, help: "Solo: hear only the soloed bands") {
                    model.config.bands[band].solo.toggle()
                }
                ToggleChip(title: "Ø", on: b.inverted, color: .cyan,
                           help: "Polarity: flip this band upside down. Use it when a speaker is wired the other way round, or its bass cancels where two sets overlap.") {
                    model.config.bands[band].inverted.toggle()
                }
                GainSlider(value: b.gainDB, range: SplitConfig.gainRange, color: color) {
                    model.config.bands[band].gainDB = $0
                }
                .frame(minWidth: 50)
                GainField(db: b.gainDB) { model.config.bands[band].gainDB = $0 }
            }
            LevelMeter(levels: meters.bands[band], stereo: b.output.stereo, color: color)
                .frame(height: 10)
                .opacity(c.isAudible(band) ? 1 : 0.4)
            Rectangle().fill(pal.line).frame(height: 1)
            HStack(spacing: 6) {
                Text("OUTPUT").font(.caption2.weight(.semibold)).foregroundColor(.secondary)
                Spacer()
                HealthDot(health: model.outputHealth(band))
            }
            EndpointPicker(end: $model.config.bands[band].output, isInput: false)
        }
        .padding(12)
        .frame(minWidth: 200, maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(pal.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.35)))
    }

    private func rangeText(_ r: (low: Double, high: Double), _ c: SplitConfig) -> String {
        let lowest = c.enabledBands.first == band, highest = c.enabledBands.last == band
        let low = lowest && c.edges[0].slope == 0 ? "0 Hz" : hzText(r.low)
        let high = highest && c.edges[SplitConfig.edgeCount - 1].slope == 0 ? "top" : hzText(r.high)
        return "\(low) – \(high)"
    }
}

struct ToggleChip: View {
    let title: String
    let on: Bool
    let color: Color
    let help: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 20)
                .foregroundColor(on ? .black : .secondary)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? color : Palette(scheme).ink.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
