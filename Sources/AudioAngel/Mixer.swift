import AppKit
import SwiftUI

// The mixer, laid out like Logic's: one row of narrow channel strips.
//
//   INPUT ↓                                  ┃ OUTPUT ↑
//   ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐      ┃ ┌──────┐ ┌──────┐
//   │source│ │      │ │      │ │      │      ┃ │source│ │      │   ← the send that feeds it
//   │effect│ │      │ │      │ │      │      ┃ │effect│ │      │   ← outputs: the limiter
//   │fader │ │      │ │      │ │      │      ┃ │fader │ │      │
//   │sends │ │      │ │      │ │      │      ┃ │device│ │      │   ← where it plays
//   └──────┘ └──────┘ └──────┘ └──────┘      ┃ └──────┘ └──────┘
//
// An input's SEND buttons (on/off, plus a level knob) are the routing: each
// one names an output. Every section has a fixed height, so faders line up
// across all strips. All sizes come from the MixerLayout in the environment
// (MixerLayout.swift): Classic or Compact.

struct MixerView: View {
    @EnvironmentObject var model: RouterModel
    @Environment(\.mixerLayout) private var L

    var body: some View {
        let inputs = model.config.inputs.count
        let outputs = model.config.outputs.count
        let lower = L.lowerHeight(outputs: outputs)

        HStack(alignment: .top, spacing: L.spacing) {
            Zone(title: "Input", arrow: "arrow.down", addTitle: "Add input",
                 canAdd: inputs < RouterConfig.maxInputs, add: { model.addInput() },
                 emptyHint: inputs == 0 ? "Add an input for each sound source: a mic, the piano, the Mac, Zoom." : nil,
                 width: L.zoneWidth(inputs)) {
                ForEach($model.config.inputs) { $slot in
                    InputStrip(slot: $slot, lowerHeight: lower)
                }
            }
            Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 2).frame(maxHeight: .infinity)
            Zone(title: "Output", arrow: "arrow.up", addTitle: "Add output",
                 canAdd: outputs < RouterConfig.maxOutputs, add: { model.addOutput() },
                 emptyHint: outputs == 0 ? "Add an output for each place sound should go: your headphones, Zoom." : nil,
                 width: L.zoneWidth(outputs)) {
                ForEach($model.config.outputs) { $slot in
                    OutputStrip(slot: $slot, lowerHeight: lower)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true) // lets the divider match the strips' height
    }
}

// MARK: - Zones

struct Zone<Content: View>: View {
    @Environment(\.mixerLayout) private var L
    let title: String
    let arrow: String
    let addTitle: String
    let canAdd: Bool
    let add: () -> Void
    let emptyHint: String?
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: L.zoneSpacing) {
            HStack(spacing: 8) {
                ZoneTitle(text: title, arrow: arrow)
                Spacer(minLength: 8)
                AddSlotButton(title: addTitle, enabled: canAdd, action: add)
            }
            .frame(width: width)
            if let emptyHint {
                EmptyZoneHint(text: emptyHint)
            } else {
                HStack(alignment: .top, spacing: L.spacing) { content }
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

struct ZoneTitle: View {
    @Environment(\.mixerLayout) private var L
    let text: String
    let arrow: String

    var body: some View {
        HStack(spacing: L.zoneTitleSize / 2) {
            Text(text.uppercased())
                .font(.system(size: L.zoneTitleSize, weight: .bold))
                .tracking(0.5)
                .foregroundColor(.primary.opacity(0.75))
            // A plain arrow, not a box: it shows the direction sound flows, it isn't a button.
            Image(systemName: arrow)
                .font(.system(size: L.zoneArrowSize, weight: .bold))
                .foregroundColor(.secondary)
        }
    }
}

struct EmptyZoneHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 260, alignment: .leading)
    }
}

struct AddSlotButton: View {
    @Environment(\.mixerLayout) private var L
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .font(.system(size: L.addButtonFontSize, weight: .medium))
                .padding(.horizontal, L.addButtonHeight / 3)
                .frame(height: L.addButtonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .background(RoundedRectangle(cornerRadius: L.pillRadius)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundColor(.secondary.opacity(0.5)))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(enabled ? title : "Up to 8")
    }
}

// MARK: - Strips

struct InputStrip: View {
    @EnvironmentObject var model: RouterModel
    @Environment(\.mixerLayout) private var L
    @Binding var slot: SlotConfig
    let lowerHeight: CGFloat

    var body: some View {
        let index = model.index(of: slot.id, isInput: true) ?? 0
        VStack(spacing: 0) {
            StripHeader(slot: $slot, isInput: true)
            StripSection(label: "Source", height: L.sourceHeight) {
                SourcePickers(slot: $slot, isInput: true)
            }
            .padding(.top, L.gapAboveSource)
            StripSection(label: "Effects", height: L.effectsHeight) {
                // Signal order: low-cut -> noise gate -> auto level -> compress -> limiter.
                VStack(alignment: .leading, spacing: L.rowGap) {
                    FXButton(effect: .lowCut, isOn: $slot.lowCut, amount: $slot.lowCutAmount, index: index)
                    FXButton(effect: .noiseGate, isOn: $slot.noiseGate, amount: $slot.noiseGateAmount, index: index)
                    FXButton(effect: .autoLevel, isOn: $slot.autoLevel, amount: $slot.autoLevelAmount, index: index)
                    FXButton(effect: .compressor, isOn: $slot.compressor, amount: $slot.compressorAmount, index: index)
                    FXButton(effect: .limiter, isOn: $slot.limiter, amount: $slot.limiterAmount, index: index)
                }
            }
            .padding(.top, L.gapAboveEffects)
            LevelBlock(db: $slot.gainDB, muted: $slot.muted, meter: .input(index), channels: slot.width)
            StripSection(label: "Send", height: lowerHeight) {
                if model.config.outputs.isEmpty {
                    Text("No outputs yet").font(.caption).foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: L.rowGap) {
                        ForEach(model.config.outputs) { output in
                            SendRow(input: slot, output: output)
                        }
                    }
                }
            }
            .padding(.top, L.gapAboveLower)
        }
        .stripCard(L)
    }
}

struct OutputStrip: View {
    @EnvironmentObject var model: RouterModel
    @Environment(\.mixerLayout) private var L
    @Binding var slot: SlotConfig
    let lowerHeight: CGFloat

    var body: some View {
        let index = model.index(of: slot.id, isInput: false) ?? 0
        VStack(spacing: 0) {
            StripHeader(slot: $slot, isInput: false)
            StripSection(label: "Source", height: L.sourceHeight) {
                BusPill(slot: $slot)
            }
            .padding(.top, L.gapAboveSource)
            // Outputs only carry the limiter, a final safety ceiling on this bus.
            // The rest of the block stays empty so every fader still lines up.
            StripSection(label: "Effects", height: L.effectsHeight) {
                FXButton(effect: .limiter, isOn: $slot.limiter, amount: $slot.limiterAmount, index: index, isOutput: true)
            }
            .padding(.top, L.gapAboveEffects)
            LevelBlock(db: $slot.gainDB, muted: $slot.muted, meter: .output(index), channels: slot.width)
            StripSection(label: "Output", height: lowerHeight) {
                SourcePickers(slot: $slot, isInput: false)
            }
            .padding(.top, L.gapAboveLower)
        }
        .stripCard(L)
    }
}

extension View {
    func stripCard(_ L: MixerLayout) -> some View {
        padding(L.cardPadding)
            .frame(width: L.stripWidth, alignment: .top)
            .background(RoundedRectangle(cornerRadius: L.cardRadius).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: L.cardRadius).strokeBorder(Color.primary.opacity(0.1)))
    }
}

struct StripSection<Content: View>: View {
    @Environment(\.mixerLayout) private var L
    let label: String
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: L.labelSpacing) {
            Text(label.uppercased())
                .font(.system(size: L.labelFontSize, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(.secondary)
            content
        }
        .frame(width: L.rowWidth, height: height, alignment: .topLeading)
    }
}

struct StripHeader: View {
    @EnvironmentObject var model: RouterModel
    @Environment(\.mixerLayout) private var L
    @Binding var slot: SlotConfig
    let isInput: Bool

    var body: some View {
        let health = model.health(slot, isInput: isInput)
        HStack(spacing: L.headerDot / 2 + 1) {
            Circle().fill(health.color).frame(width: L.headerDot, height: L.headerDot).help(health.help)
            TextField("Name", text: $slot.name)
                .textFieldStyle(.plain)
                .font(.system(size: L.headerFontSize, weight: .semibold))
            Menu {
                Button("Move left") { model.move(slot.id, isInput: isInput, by: -1) }
                Button("Move right") { model.move(slot.id, isInput: isInput, by: 1) }
                Divider()
                Button("Remove \(slot.name)") { model.remove(slot.id, isInput: isInput) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: L.headerFontSize))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(width: L.rowWidth, height: L.headerHeight)
    }
}

struct SourcePickers: View {
    @EnvironmentObject var model: RouterModel
    @Environment(\.mixerLayout) private var L
    @Binding var slot: SlotConfig
    let isInput: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: L.rowGap) {
            Picker("Device", selection: deviceBinding) {
                Text("— None —").tag(String?.none)
                if let uid = slot.deviceUID, model.device(uid) == nil {
                    Text("\(slot.deviceName ?? "Unknown") (not connected)").tag(Optional(uid))
                }
                ForEach(isInput ? model.inputDevices : model.outputDevices) { d in
                    Text(d.name).tag(Optional(d.uid))
                }
            }
            .labelsHidden()
            .controlSize(L.pickerSize)
            .frame(width: L.rowWidth, height: L.pickerHeight)

            Picker("Channels", selection: channelBinding) {
                ForEach(channelChoices, id: \.code) { choice in
                    Text(choice.label).tag(choice.code)
                }
            }
            .labelsHidden()
            .controlSize(L.pickerSize)
            .frame(width: L.rowWidth, height: L.pickerHeight)
            .disabled(slot.deviceUID == nil)
        }
    }

    private var deviceBinding: Binding<String?> {
        Binding(
            get: { slot.deviceUID },
            set: { uid in
                guard uid != slot.deviceUID else { return }
                let d = model.device(uid)
                let channels = (isInput ? d?.inputChannels : d?.outputChannels) ?? 2
                slot.deviceUID = uid
                slot.deviceName = d?.name ?? slot.deviceName
                slot.firstChannel = 0
                slot.stereo = slot.stereo && channels >= 2
            }
        )
    }

    private struct ChannelChoice {
        var first: Int
        var stereo: Bool
        var code: Int { first * 2 + (stereo ? 1 : 0) }
        var label: String { stereo ? "Ch \(first + 1)+\(first + 2) stereo" : "Ch \(first + 1) mono" }
    }

    private var channelChoices: [ChannelChoice] {
        let d = model.device(slot.deviceUID)
        let count = (isInput ? d?.inputChannels : d?.outputChannels) ?? 0
        var choices: [ChannelChoice] = []
        if count >= 2 {
            for first in stride(from: 0, to: count - 1, by: 2) { choices.append(ChannelChoice(first: first, stereo: true)) }
        }
        for first in 0..<count { choices.append(ChannelChoice(first: first, stereo: false)) }
        let current = ChannelChoice(first: slot.firstChannel, stereo: slot.stereo)
        if !choices.contains(where: { $0.code == current.code }) { choices.insert(current, at: 0) }
        return choices
    }

    private var channelBinding: Binding<Int> {
        Binding(
            get: { slot.firstChannel * 2 + (slot.stereo ? 1 : 0) },
            set: { code in
                slot.firstChannel = code / 2
                slot.stereo = code % 2 == 1
            }
        )
    }
}

// MARK: - Pills: effects and sends share one look

/// The on/off button used by every effect and every send: same font, width,
/// height and status dot. Long send names are cut short with "…", never shrunk.
struct StripPill<Status: View>: View {
    let title: String
    let on: Bool
    let help: String
    var enabled = true
    let action: () -> Void
    @ViewBuilder let status: Status

    var body: some View {
        Button(action: action) {
            PillFace(title: title, on: on) { status }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

struct PillFace<Status: View>: View {
    @Environment(\.mixerLayout) private var L
    let title: String
    let on: Bool
    @ViewBuilder let status: Status

    var body: some View {
        HStack(spacing: L.dotGap) {
            status.frame(width: L.dot, height: L.dot)
            Text(title)
                .font(L.pillFont)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, L.pillPadding)
        .frame(width: L.pillWidth, height: L.control)
        .background(RoundedRectangle(cornerRadius: L.pillRadius)
            .fill(on ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06)))
        .foregroundColor(on ? .primary : .secondary)
        .contentShape(Rectangle())
    }
}

/// One send on an input: on/off, and a knob for how much.
struct SendRow: View {
    @EnvironmentObject var model: RouterModel
    @Environment(\.mixerLayout) private var L
    let input: SlotConfig
    let output: SlotConfig

    var body: some View {
        let binding = model.routeBinding(input.id, output.id)
        let feedback = model.isFeedback(input, output)
        let on = binding.wrappedValue.on && !feedback

        HStack(spacing: L.knobGap) {
            StripPill(title: output.busName, on: on,
                      help: feedback ? "Blocked: \(input.name) is on the same loopback as \(output.name), so it would feed back on itself."
                          : on ? "Sending \(input.name) to \(output.name). Click to stop."
                          : "Send \(input.name) to \(output.name)",
                      enabled: !feedback,
                      action: { binding.wrappedValue.on.toggle() }) {
                if feedback {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: L.dot + 1))
                        .foregroundColor(.orange)
                } else {
                    Circle().fill(on ? Color.green : Color.secondary.opacity(0.35))
                }
            }

            Knob(db: binding.gainDB, active: on)
                .help("Send level to \(output.name): \(dbText(binding.wrappedValue.gainDB)). Drag up or down; double-click for 0 dB; right-click for presets.")
        }
    }
}

/// On an output strip: the send that feeds it. Lit when any input is sending here.
struct BusPill: View {
    @EnvironmentObject var model: RouterModel
    @Environment(\.mixerLayout) private var L
    @Binding var slot: SlotConfig
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        let feeders = model.config.inputs.filter { input in
            model.config.route(input.id, slot.id).on && !model.isFeedback(input, slot)
        }
        let fed = !feeders.isEmpty

        Group {
            if editing {
                TextField("Send name", text: $slot.sendName)
                    .textFieldStyle(.plain)
                    .font(L.pillFont)
                    .focused($focused)
                    .onSubmit { editing = false }
                    .onChange(of: focused) { if !$0 { editing = false } }
                    .onAppear { focused = true }
                    .padding(.horizontal, L.pillPadding)
                    .frame(width: L.pillWidth, height: L.control)
                    .background(RoundedRectangle(cornerRadius: L.pillRadius).fill(Color(nsColor: .textBackgroundColor)))
            } else {
                PillFace(title: slot.busName, on: fed) {
                    Circle().fill(fed ? Color.green : Color.secondary.opacity(0.35))
                }
            }
        }
        .onTapGesture(count: 2) {
            if slot.sendName.isEmpty { slot.sendName = slot.busName }
            editing = true
        }
        .help(fed
              ? "Fed by \(feeders.map(\.name).joined(separator: ", ")). Double-click to rename this send."
              : "Nothing is sent here yet: turn on “\(slot.busName)” under SEND on an input. Double-click to rename.")
    }
}

// MARK: - Level: fader, meter, readouts and mute

/// The fader and its meter, then the level, the peak and M. Compact puts M, the
/// level and the peak on one row; Classic gives M a row of its own below.
struct LevelBlock: View {
    @Environment(\.mixerLayout) private var L
    @Binding var db: Double
    @Binding var muted: Bool
    let meter: MeterSource
    let channels: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: L.meterGap) {
                Fader(db: $db)
                VMeter(source: meter, channels: channels)
                    .padding(.vertical, L.faderCap.height / 2)
            }
            .frame(width: L.rowWidth, height: L.faderHeight)
            .padding(.top, L.gapAboveFader)

            if L.muteBesideReadouts {
                HStack(spacing: L.readoutGap) {
                    MuteButton(muted: $muted)
                    DBReadout(db: $db)
                    PeakHoldBadge(source: meter)
                }
                .frame(width: L.rowWidth)
                .padding(.top, L.gapAboveReadouts)
            } else {
                HStack(spacing: L.readoutGap) {
                    DBReadout(db: $db)
                    PeakHoldBadge(source: meter)
                }
                .frame(width: L.rowWidth)
                .padding(.top, L.gapAboveReadouts)
                MuteButton(muted: $muted)
                    .padding(.top, L.gapAboveMute)
            }
        }
    }
}

struct Fader: View {
    @Environment(\.mixerLayout) private var L
    @Binding var db: Double
    @State private var dragStart: Double?

    // Travel against dB: most of the throw is spent where levels are set.
    private static let taper: [(db: Double, pos: Double)] = [
        (-60, 0), (-40, 0.1), (-20, 0.3), (-10, 0.5), (0, 0.75), (12, 1),
    ]

    static func position(_ db: Double) -> Double {
        guard db > taper[0].db else { return 0 }
        for k in 1..<taper.count where db <= taper[k].db {
            let a = taper[k - 1], b = taper[k]
            return a.pos + (db - a.db) / (b.db - a.db) * (b.pos - a.pos)
        }
        return 1
    }

    static func db(at pos: Double) -> Double {
        guard pos > 0 else { return taper[0].db }
        for k in 1..<taper.count where pos <= taper[k].pos {
            let a = taper[k - 1], b = taper[k]
            return a.db + (pos - a.pos) / (b.pos - a.pos) * (b.db - a.db)
        }
        return taper[taper.count - 1].db
    }

    /// Shared by the fader and the send knobs: relative drag, a detent at 0 dB, 0.1 dB steps.
    static func dragged(from start: Double, by delta: Double) -> Double {
        let p = min(max(start + delta, 0), 1)
        let value = db(at: p)
        return abs(value) < 0.4 ? 0 : (value * 10).rounded() / 10
    }

    var body: some View {
        let cap = L.faderCap
        GeometryReader { geo in
            let travel = max(geo.size.height - cap.height, 1)
            let pos = Self.position(db)
            let capTop = travel * (1 - pos)
            ZStack(alignment: .top) {
                Capsule().fill(Color.primary.opacity(0.12))
                    .frame(width: L.faderTrack, height: travel)
                    .offset(y: cap.height / 2)
                Capsule().fill(Color.accentColor)
                    .frame(width: L.faderTrack, height: travel * pos)
                    .offset(y: capTop + cap.height / 2)
                Rectangle().fill(Color.primary.opacity(0.45)) // 0 dB mark
                    .frame(width: cap.width, height: 1)
                    .offset(y: travel * (1 - Self.position(0)) + cap.height / 2)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.2)))
                    .overlay(Rectangle().fill(Color.black.opacity(0.35)).frame(height: 1)) // the cap's centre line
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: cap.width, height: cap.height)
                    .offset(y: capTop)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                // Relative, like a real fader: grabbing it never makes it jump.
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? pos
                        dragStart = start
                        db = Self.dragged(from: start, by: -Double(value.translation.height / travel))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { db = 0 }
        }
        .frame(width: cap.width)
        .contextMenu { QuickGainMenu(db: $db) }
        .help("Drag to set the level. Double-click for 0 dB; right-click for presets.")
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(dbText(db))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: db = min(12, db + 1)
            case .decrement: db = max(-60, db - 1)
            @unknown default: break
            }
        }
    }
}

/// What every knob looks like, sends and effects alike: an arc from 7 o'clock
/// (0) to 5 o'clock (1), and a pointer. A send at 0 dB and an effect at 100%
/// both sit at the same spot, about 2 o'clock.
struct KnobFace: View {
    @Environment(\.mixerLayout) private var L
    let position: Double
    let active: Bool

    var body: some View {
        let pos = max(0, min(1, position))
        let stroke = StrokeStyle(lineWidth: L.knobStroke, lineCap: .round)
        ZStack {
            Circle()
                .trim(from: 0.125, to: 0.875)
                .stroke(Color.primary.opacity(0.15), style: stroke)
            Circle()
                .trim(from: 0.125, to: 0.125 + 0.75 * pos)
                .stroke(active ? Color.accentColor : Color.secondary.opacity(0.5), style: stroke)
        }
        .rotationEffect(.degrees(90))
        .overlay(
            Capsule()
                .fill(Color.primary.opacity(active ? 0.75 : 0.4))
                .frame(width: L.knobStroke * 0.6, height: L.knobSize * 0.28)
                .offset(y: -L.knobSize * 0.19)
                .rotationEffect(.degrees(-135 + 270 * pos))
        )
        .padding(L.knobStroke * 0.6)
        .frame(width: L.knobSize, height: L.knobSize)
        .contentShape(Rectangle())
    }
}

/// A send-level knob, on the same dB taper as the fader: −∞ to +12 dB.
struct Knob: View {
    @Binding var db: Double
    let active: Bool
    @State private var dragStart: Double?

    var body: some View {
        let pos = Fader.position(db)
        KnobFace(position: pos, active: active)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? pos
                        dragStart = start
                        db = Fader.dragged(from: start, by: -Double(value.translation.height) / 120)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { db = 0 }
            .contextMenu { QuickGainMenu(db: $db) }
            .accessibilityElement()
            .accessibilityLabel("Send level")
            .accessibilityValue(dbText(db))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: db = min(12, db + 1)
                case .decrement: db = max(-60, db - 1)
                @unknown default: break
                }
            }
    }
}

/// An effect's amount, 0–150%, 100% being the effect as designed. It behaves
/// like a send knob: 100% sits where 0 dB does, double-click returns there, and
/// right-click offers 120 / 100 / 80%.
struct EffectAmountKnob: View {
    @Binding var amount: Double
    let active: Bool
    @State private var dragStart: Double?

    static let maximum = 1.5

    /// 0% at 7 o'clock, 100% where a send's 0 dB sits, 150% at 5 o'clock.
    static func position(_ amount: Double) -> Double {
        let zero = Fader.position(0)
        return amount <= 1 ? max(0, amount) * zero : zero + (min(amount, maximum) - 1) / (maximum - 1) * (1 - zero)
    }

    static func amount(at pos: Double) -> Double {
        let zero = Fader.position(0)
        let p = min(max(pos, 0), 1)
        return p <= zero ? p / zero : 1 + (p - zero) / (1 - zero) * (maximum - 1)
    }

    /// Relative drag, a detent at 100%, whole-percent steps.
    static func dragged(from start: Double, by delta: Double) -> Double {
        let value = amount(at: start + delta)
        return abs(value - 1) < 0.03 ? 1 : (value * 100).rounded() / 100
    }

    static func percent(_ amount: Double) -> String { "\(Int((amount * 100).rounded()))%" }

    var body: some View {
        let pos = Self.position(amount)
        KnobFace(position: pos, active: active)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? pos
                        dragStart = start
                        amount = Self.dragged(from: start, by: -Double(value.translation.height) / 120)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { amount = 1 }
            .contextMenu {
                Button("Set to 120%") { amount = 1.2 }
                Button("Set to 100%") { amount = 1 }
                Button("Set to 80%") { amount = 0.8 }
            }
            .accessibilityElement()
            .accessibilityLabel("Effect amount")
            .accessibilityValue(Self.percent(amount))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: amount = min(Self.maximum, amount + 0.05)
                case .decrement: amount = max(0, amount - 0.05)
                @unknown default: break
                }
            }
    }
}

struct QuickGainMenu: View {
    @Binding var db: Double

    var body: some View {
        Button("Set to +5 dB") { db = 5 }
        Button("Set to 0 dB") { db = 0 }
        Button("Set to −5 dB") { db = -5 }
    }
}

/// The box shared by the level readout and the peak badge, so they're always identical.
struct ReadoutBox: ViewModifier {
    @Environment(\.mixerLayout) private var L
    var fill: Color = .clear
    var stroke: Color = Color.primary.opacity(0.25)
    var lineWidth: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .font(.system(size: L.readoutFontSize).monospacedDigit())
            .lineLimit(1)
            .frame(width: L.readoutWidth, height: L.readoutHeight)
            .background(RoundedRectangle(cornerRadius: 3).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(stroke, lineWidth: lineWidth))
            .contentShape(Rectangle())
    }
}

/// The level, as a number you can click and type into.
struct DBReadout: View {
    @Binding var db: Double
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("dB", text: $text)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false } // Esc: leave it as it was
                    .onChange(of: focused) { if !$0 && editing { commit() } }
                    .onAppear { focused = true }
            } else {
                Text(dbText(db))
            }
        }
        .modifier(ReadoutBox(fill: editing ? Color(nsColor: .textBackgroundColor) : .clear,
                             stroke: editing ? Color.accentColor : Color.primary.opacity(0.25),
                             lineWidth: editing ? 1.5 : 1))
        .onTapGesture {
            guard !editing else { return }
            text = db <= -59.9 ? "-inf" : String(format: "%+.1f", db)
            editing = true
        }
        .contextMenu { QuickGainMenu(db: $db) }
        .help("Click to type a level in dB (−60 to +12, or −inf). Right-click for +5 / 0 / −5 dB.")
    }

    private func commit() {
        if let value = Self.parse(text) { db = value }
        editing = false
    }

    /// Accepts "3", "+3", "-6.5", "−6,5 dB", "-inf". Anything else leaves the level alone.
    static func parse(_ input: String) -> Double? {
        var t = input.lowercased()
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "db", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        if ["-inf", "-∞", "inf", "∞", "off"].contains(t) { return -60 }
        if t.hasPrefix("+") { t.removeFirst() }
        guard let value = Double(t), value.isFinite else { return nil }
        return min(max((value * 10).rounded() / 10, -60), 12)
    }
}

/// Next to the level readout: the loudest peak since it was last clicked, and
/// whether that peak reached 0 dBFS — held red until you reset it, so a clip
/// caught while you were tabbed away is never missed.
struct PeakHoldBadge: View {
    @EnvironmentObject var meters: MeterStore
    let source: MeterSource

    var body: some View {
        let hold = meters.peakHold(source)
        Button {
            meters.resetPeakHold(source)
        } label: {
            Text(hold.db <= -59.9 ? "−∞" : String(format: "%.1f", hold.db))
                .foregroundColor(hold.clipped ? .white : .secondary)
                .modifier(ReadoutBox(fill: hold.clipped ? .red : .clear,
                                     stroke: hold.clipped ? .red : Color.primary.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .help((hold.clipped ? "Clipped: reached 0 dBFS. " : "Peak since last reset: \(String(format: "%.1f", hold.db)) dBFS. ")
              + "Click to reset.")
    }
}

struct MuteButton: View {
    @Environment(\.mixerLayout) private var L
    @Binding var muted: Bool

    var body: some View {
        Button {
            muted.toggle()
        } label: {
            Text("M")
                .font(.system(size: L.muteFontSize, weight: .bold))
                .frame(width: L.muteWidth, height: L.readoutHeight)
                .background(RoundedRectangle(cornerRadius: 3).fill(muted ? Color.red : Color.primary.opacity(0.1)))
                .foregroundColor(muted ? .white : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(muted ? "Unmute" : "Mute")
    }
}

enum MeterSource {
    case input(Int)
    case output(Int)
}

struct VMeter: View {
    @EnvironmentObject var meters: MeterStore
    @Environment(\.mixerLayout) private var L
    let source: MeterSource
    let channels: Int

    var body: some View {
        let levels: [Float] = {
            switch source {
            case .input(let i): return meters.input(i)
            case .output(let o): return meters.output(o)
            }
        }()
        HStack(spacing: 2) {
            ForEach(0..<max(channels, 1), id: \.self) { c in
                VMeterBar(level: c < levels.count ? levels[c] : 0)
                    .frame(width: L.meterWidth)
            }
        }
    }
}

struct VMeterBar: View {
    let level: Float

    private static let gradient = LinearGradient(
        gradient: Gradient(stops: [
            .init(color: .green, location: 0),
            .init(color: .green, location: 0.7),
            .init(color: .yellow, location: 0.87),
            .init(color: .red, location: 1),
        ]),
        startPoint: .bottom, endPoint: .top)

    var body: some View {
        GeometryReader { geo in
            let db = level > 0 ? 20 * log10(level) : -100
            let fraction = CGFloat(max(0, min(1, (db + 60) / 60)))
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Self.gradient)
                    .mask(alignment: .bottom) { Rectangle().frame(height: geo.size.height * fraction) }
            }
        }
    }
}

// MARK: - Effects

/// The five hard-coded channel-strip effects, in signal order.
enum InputEffect: CaseIterable {
    case lowCut, noiseGate, autoLevel, compressor, limiter

    var title: String {
        switch self {
        case .lowCut: return "Low-cut"
        case .noiseGate: return "Noise gate"
        case .autoLevel: return "Auto level"
        case .compressor: return "Compress"
        case .limiter: return "Limiter"
        }
    }

    var help: String {
        switch self {
        case .lowCut:
            return "Removes rumble below 80 Hz (12 dB/octave), the standard mixing-desk low-cut. The knob moves the cutoff: 120% is 96 Hz, 80% is 64 Hz."
        case .noiseGate:
            return "Silences a steady background noise (fans, hiss, hum) while speech, piano and every sudden sound pass straight through at full level. It learns the room's noise by itself during pauses. The knob sets how strict it is: above 100% for a noisier room, below to let more through."
        case .autoLevel:
            return "Evens out the student's level so you don't have to ride the volume: passages that drop well below their normal level are lifted back up (the light turns yellow), and sudden jumps are capped before they reach you (red). It learns their normal level while they play and leaves it alone during pauses. The knob sets how strongly it acts."
        case .compressor:
            return "Gentle leveller (2:1 above −24 dBFS, soft knee, +2 dB make-up). Shouts come down a little, whispers come up a little. The light turns yellow while it's working. The knob sets how strongly it acts."
        case .limiter:
            return "Safety limiter. At 100%, nothing from this strip goes above −1 dBFS; above 100% the ceiling drops (150% is −6 dBFS), below 100% some of a peak gets through. It stays out of the way until a peak would overload; the light turns orange while it's catching one."
        }
    }

    /// The status light while the effect is working (Low-cut always is, so it stays green).
    var workingColor: Color {
        switch self {
        case .lowCut: return .green
        case .noiseGate: return .mint
        case .autoLevel: return .red // capping a jump; lifting a quiet passage is yellow (see FXButton)
        case .compressor: return .yellow
        case .limiter: return .orange
        }
    }
}

struct FXButton: View {
    @EnvironmentObject var meters: MeterStore
    @Environment(\.mixerLayout) private var L
    let effect: InputEffect
    @Binding var isOn: Bool
    @Binding var amount: Double
    let index: Int
    var isOutput: Bool = false

    var body: some View {
        HStack(spacing: L.knobGap) {
            StripPill(title: effect.title, on: isOn,
                      help: isOn ? effect.help : "\(effect.title) is off. \(effect.help)",
                      action: { isOn.toggle() }) {
                Circle().fill(light)
            }
            EffectAmountKnob(amount: $amount, active: isOn)
                .help("\(effect.title): \(EffectAmountKnob.percent(amount)). Drag up or down; double-click for 100%; right-click for presets.")
        }
    }

    /// Grey when off, green when on and idle, the effect's colour while it works.
    private var light: Color {
        guard isOn else { return Color.secondary.opacity(0.3) }
        let reduction = isOutput ? meters.outputReduction(index) : meters.reduction(index, effect)
        if reduction > 0.5 { return effect.workingColor }
        if effect == .autoLevel, !isOutput, meters.lift(index) > 0.5 { return .yellow }
        return .green
    }
}
