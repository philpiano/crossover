import AppKit
import SwiftUI

/// Every size in the mixer, in two sets: Classic, roomy and easy to read with the
/// window on its own; and Compact, as tight as it goes, for teaching with other
/// windows open. View › Compact Mode switches between them while the audio runs.
///
/// In both, sizes are derived rather than tuned by eye: effects and sends share one
/// pill (font, width, height) and one knob size. The pill is exactly as wide as the
/// widest effect name needs at its font, and everything else in a strip is as wide
/// as a pill plus its knob, so no label is ever shrunk to fit.
struct MixerLayout: Equatable {
    // Pills and knobs
    var pillFontSize: CGFloat
    var pillPadding: CGFloat
    var dot: CGFloat
    var dotGap: CGFloat
    var control: CGFloat            // pill height
    var pillRadius: CGFloat
    var knobSize: CGFloat
    var knobStroke: CGFloat
    var knobGap: CGFloat

    // Strips
    var cardPadding: CGFloat
    var cardRadius: CGFloat
    var spacing: CGFloat            // between strips, and either side of the input/output line
    var rowGap: CGFloat             // between stacked rows
    var labelFontSize: CGFloat
    var labelSpacing: CGFloat
    var labelBlock: CGFloat         // a section's label and the space under it
    var pickerSize: ControlSize
    var pickerHeight: CGFloat
    var headerFontSize: CGFloat
    var headerHeight: CGFloat
    var headerDot: CGFloat
    // Space above each part of a strip, top to bottom.
    var gapAboveSource: CGFloat
    var gapAboveEffects: CGFloat
    var gapAboveFader: CGFloat
    var gapAboveReadouts: CGFloat
    var gapAboveMute: CGFloat       // Classic only: Compact puts M on the readout row
    var gapAboveLower: CGFloat

    // Fader, meters, readouts
    var faderHeight: CGFloat
    var faderTrack: CGFloat
    var faderCap: CGSize
    var meterWidth: CGFloat
    var meterGap: CGFloat
    var readoutHeight: CGFloat
    var readoutFontSize: CGFloat
    var readoutGap: CGFloat
    var muteWidth: CGFloat
    var muteFontSize: CGFloat
    /// Compact: M, the level and the peak share one row. Classic: M sits below.
    var muteBesideReadouts: Bool

    // Around the strips
    var zoneTitleSize: CGFloat
    var zoneArrowSize: CGFloat
    var addButtonHeight: CGFloat
    var addButtonFontSize: CGFloat
    var zoneSpacing: CGFloat        // between a zone's title row and its strips
    var minZoneWidth: CGFloat       // room for the title and the Add button
    var paddingSides: CGFloat
    var paddingTop: CGFloat
    var paddingBottom: CGFloat

    // MARK: Derived

    var pillFont: Font { .system(size: pillFontSize, weight: .semibold) }

    /// Fits the widest effect name ("Noise gate") at the pill font; set by `measured()`.
    var pillWidth: CGFloat = 0

    /// Measures the pill once. SwiftUI sets system text a few points wider than
    /// AppKit measures it, hence the allowance.
    func measured() -> MixerLayout {
        let font = NSFont.systemFont(ofSize: pillFontSize, weight: .semibold)
        let widest = InputEffect.allCases
            .map { ($0.title as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 60
        var copy = self
        copy.pillWidth = ceil(pillPadding * 2 + dot + dotGap + widest + pillFontSize * 0.65)
        return copy
    }

    /// The width of everything in a strip: a pill and its knob.
    var rowWidth: CGFloat { pillWidth + knobGap + knobSize }
    var stripWidth: CGFloat { rowWidth + cardPadding * 2 }
    var sourceHeight: CGFloat { labelBlock + pickerHeight * 2 + rowGap }
    var effectsHeight: CGFloat {
        let n = CGFloat(InputEffect.allCases.count)
        return labelBlock + control * n + rowGap * (n - 1)
    }
    /// The level readout and the peak badge are always the same size.
    var readoutWidth: CGFloat {
        muteBesideReadouts ? (rowWidth - muteWidth - readoutGap * 2) / 2 : (rowWidth - readoutGap) / 2
    }

    func zoneWidth(_ strips: Int) -> CGFloat {
        let n = CGFloat(strips)
        return max(minZoneWidth, n * stripWidth + max(0, n - 1) * spacing)
    }

    /// Inputs' SEND list and outputs' OUTPUT pickers share this height.
    func lowerHeight(outputs: Int) -> CGFloat {
        let n = CGFloat(outputs)
        return labelBlock + max(n * control + max(0, n - 1) * rowGap, pickerHeight * 2 + rowGap)
    }

    // MARK: The two sets

    static let classic = MixerLayout(
        pillFontSize: 12, pillPadding: 9, dot: 7, dotGap: 6, control: 24, pillRadius: 6,
        knobSize: 20, knobStroke: 3, knobGap: 6,
        cardPadding: 10, cardRadius: 10, spacing: 10, rowGap: 5,
        labelFontSize: 10, labelSpacing: 4, labelBlock: 17, pickerSize: .regular, pickerHeight: 22,
        headerFontSize: 13, headerHeight: 20, headerDot: 8,
        gapAboveSource: 8, gapAboveEffects: 10, gapAboveFader: 10, gapAboveReadouts: 8, gapAboveMute: 6, gapAboveLower: 10,
        faderHeight: 150, faderTrack: 12, faderCap: CGSize(width: 30, height: 12), meterWidth: 12, meterGap: 6,
        readoutHeight: 20, readoutFontSize: 11, readoutGap: 6, muteWidth: 28, muteFontSize: 11, muteBesideReadouts: false,
        zoneTitleSize: 15, zoneArrowSize: 15, addButtonHeight: 26, addButtonFontSize: 12, zoneSpacing: 14, minZoneWidth: 300,
        paddingSides: 20, paddingTop: 18, paddingBottom: 20).measured()

    static let compact = MixerLayout(
        pillFontSize: 11, pillPadding: 6, dot: 6, dotGap: 5, control: 18, pillRadius: 5,
        knobSize: 16, knobStroke: 2.5, knobGap: 4,
        cardPadding: 5, cardRadius: 7, spacing: 4, rowGap: 3,
        labelFontSize: 9, labelSpacing: 1, labelBlock: 12, pickerSize: .small, pickerHeight: 19,
        headerFontSize: 11, headerHeight: 15, headerDot: 6,
        gapAboveSource: 1, gapAboveEffects: 4, gapAboveFader: 0, gapAboveReadouts: 0, gapAboveMute: 0, gapAboveLower: 3,
        faderHeight: 105, faderTrack: 12, faderCap: CGSize(width: 24, height: 8), meterWidth: 12, meterGap: 4,
        readoutHeight: 15, readoutFontSize: 9, readoutGap: 3, muteWidth: 18, muteFontSize: 9, muteBesideReadouts: true,
        zoneTitleSize: 13, zoneArrowSize: 12, addButtonHeight: 20, addButtonFontSize: 11, zoneSpacing: 6, minZoneWidth: 180,
        paddingSides: 8, paddingTop: 6, paddingBottom: 6).measured()
}

private struct MixerLayoutKey: EnvironmentKey {
    static let defaultValue = MixerLayout.classic
}

extension EnvironmentValues {
    var mixerLayout: MixerLayout {
        get { self[MixerLayoutKey.self] }
        set { self[MixerLayoutKey.self] = newValue }
    }
}

/// View menu settings, saved between launches.
enum ViewSettings {
    static let compactMode = "AudioAngel.View.compactMode"
    static let showStatusBar = "AudioAngel.View.showStatusBar"
}
