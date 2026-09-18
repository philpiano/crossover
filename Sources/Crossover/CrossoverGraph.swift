import AppKit
import SplitCore
import SwiftUI

/// Where things sit in the graph: frequency across (log), level up the side.
struct GraphGeometry {
    static let lowHz = SpectrumStore.lowHz
    static let highHz = SpectrumStore.highHz
    static let topDB = 12.0
    static let bottomDB = -48.0

    let plot: CGRect

    init(size: CGSize) {
        plot = CGRect(x: 40, y: 34, width: max(size.width - 52, 10), height: max(size.height - 58, 10))
    }

    func x(_ hz: Double) -> CGFloat {
        let t = log(min(max(hz, Self.lowHz), Self.highHz) / Self.lowHz) / log(Self.highHz / Self.lowHz)
        return plot.minX + CGFloat(t) * plot.width
    }

    func hz(_ x: CGFloat) -> Double {
        let t = Double((x - plot.minX) / plot.width)
        return Self.lowHz * pow(Self.highHz / Self.lowHz, min(max(t, 0), 1))
    }

    func y(_ db: Double) -> CGFloat {
        let t = (Self.topDB - min(max(db, Self.bottomDB - 6), Self.topDB + 6)) / (Self.topDB - Self.bottomDB)
        return plot.minY + CGFloat(t) * plot.height
    }

    /// The analyser has its own scale: its floor at the bottom, 0 dBFS near the top.
    func spectrumY(_ db: Float) -> CGFloat {
        let lo = SpectrumStore.floorDB, hi = SpectrumStore.ceilingDB + 6
        let t = CGFloat((min(max(db, lo), hi) - lo) / (hi - lo))
        return plot.maxY - t * plot.height
    }

    /// Where a band's level dot sits across: the middle of its range, in octaves.
    func bandCentreX(_ config: SplitConfig, _ band: Int) -> CGFloat {
        let r = config.range(of: band)
        return x(sqrt(max(r.low, Self.lowHz) * min(r.high, Self.highHz)))
    }

    func dot(_ config: SplitConfig, _ band: Int) -> CGPoint {
        CGPoint(x: bandCentreX(config, band), y: y(config.bands[band].gainDB))
    }

    /// The level readout above a band's dot.
    func gainLabel(_ config: SplitConfig, _ band: Int) -> CGRect {
        let d = dot(config, band)
        return CGRect(x: d.x - 32, y: d.y - 25, width: 64, height: 17)
    }

    struct EdgeLabel {
        let edge: Int
        let text: String
        var rect: CGRect
    }

    static let edgeLabelWidth: CGFloat = 62

    /// The frequency labels along the top, one per edge in use, pushed apart if
    /// they'd overlap.
    func edgeLabels(_ config: SplitConfig) -> [EdgeLabel] {
        let w = Self.edgeLabelWidth
        var xs = config.activeEdges.map { x(config.edges[$0].hz) }
        for i in xs.indices.dropFirst() where xs[i] - xs[i - 1] < w + 4 { xs[i] = xs[i - 1] + w + 4 }
        for i in xs.indices.reversed() {
            xs[i] = min(xs[i], i == xs.count - 1 ? plot.maxX - w / 2 + 6 : xs[i + 1] - w - 4)
        }
        return zip(config.activeEdges, xs).map { k, x in
            let e = config.edges[k]
            let off = SplitConfig.isOuter(k) && e.slope == 0
            return EdgeLabel(edge: k, text: off ? "off" : hzText(e.hz), rect: CGRect(x: x - w / 2, y: 7, width: w, height: 19))
        }
    }
}

/// The response of each band, computed by the engine's own filter design and
/// cached until the crossovers or the bands change.
final class ResponseCache {
    static let shared = ResponseCache()
    static let pointCount = 320

    private var key: [EdgeConfig] = []
    private var mask: UInt32 = 0
    private var rate: Double = 0
    private var curves: [[Double]] = []

    func curves(_ edges: [EdgeConfig], mask: UInt32, sampleRate: Double) -> [[Double]] {
        if edges == key && mask == self.mask && rate == sampleRate && !curves.isEmpty { return curves }
        let c = edges.map { sc_edge(hz: Float($0.hz), slope: Int32($0.slope)) }
        curves = (0..<SplitConfig.bandCount).map { band in
            (0..<Self.pointCount).map { i in
                c.withUnsafeBufferPointer { sc_band_response_db($0.baseAddress, mask, sampleRate, Int32(band), Self.hz(at: i)) }
            }
        }
        key = edges
        self.mask = mask
        rate = sampleRate
        return curves
    }

    static func hz(at i: Int) -> Double {
        GraphGeometry.lowHz * pow(GraphGeometry.highHz / GraphGeometry.lowHz, Double(i) / Double(pointCount - 1))
    }
}

/// The big display: the live spectrum of the input, and over it the bands'
/// crossover curves.
///   • Drag a crossover line left or right to move it; double-click its label
///     along the top to type a frequency.
///   • Drag a band's dot up or down to set its level; double-click the dot for
///     0 dB, or double-click the level above it to type one.
struct CrossoverGraph: View {
    @EnvironmentObject var model: SplitModel
    @Environment(\.colorScheme) private var scheme

    private enum Target: Equatable { case edge(Int), gain(Int) }
    @State private var dragging: Target?
    @State private var hovering: Target?
    @State private var dragStartDB = 0.0
    @State private var editing: Target?
    @State private var editText = ""
    @State private var editAt = CGPoint.zero

    var body: some View {
        GeometryReader { g in
            let geo = GraphGeometry(size: g.size)
            let pal = Palette(scheme)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(pal.graph)
                GridLayer(geo: geo, pal: pal)
                SpectrumLayer(geo: geo, config: model.config, pal: pal)
                CurvesLayer(geo: geo, config: model.config, sampleRate: rate, pal: pal,
                            highlight: highlighted, editing: editing.map { t -> Int in
                                if case .edge(let k) = t { return k } else { return -1 }
                            })
                if editing != nil {
                    InlineEditor(text: $editText, commit: commitEdit, cancel: { editing = nil })
                        .frame(width: 76)
                        .position(editAt)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(pal.line))
            .contentShape(Rectangle())
            .gesture(drag(geo))
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in doubleClick(at: tap.location, geo) })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let t = target(at: p, geo)
                    if t != hovering { hovering = t }
                    switch t {
                    case .edge: NSCursor.resizeLeftRight.set()
                    case .gain: NSCursor.resizeUpDown.set()
                    case nil: NSCursor.arrow.set()
                    }
                case .ended:
                    hovering = nil
                    NSCursor.arrow.set()
                }
            }
        }
    }

    private var rate: Double {
        model.status.sampleRate > 0 ? model.status.sampleRate : model.config.sampleRate
    }

    private var highlighted: (edge: Int?, band: Int?) {
        switch dragging ?? hovering {
        case .edge(let k): return (k, nil)
        case .gain(let b): return (nil, b)
        case nil: return (nil, nil)
        }
    }

    /// Band dots first (they're small), then an edge label, then the nearest line.
    private func target(at p: CGPoint, _ geo: GraphGeometry) -> Target? {
        let c = model.config
        for b in c.enabledBands {
            let d = geo.dot(c, b)
            if hypot(p.x - d.x, p.y - d.y) <= 11 { return .gain(b) }
        }
        if let l = geo.edgeLabels(c).first(where: { $0.rect.insetBy(dx: -2, dy: -3).contains(p) }) { return .edge(l.edge) }
        var best: (k: Int, d: CGFloat)?
        for k in c.activeEdges {
            let d = abs(p.x - geo.x(c.edges[k].hz))
            if d <= 9, p.y > geo.plot.minY - 8, d < (best?.d ?? .infinity) { best = (k, d) }
        }
        return best.map { .edge($0.k) }
    }

    private func doubleClick(at p: CGPoint, _ geo: GraphGeometry) {
        let c = model.config
        if let l = geo.edgeLabels(c).first(where: { $0.rect.insetBy(dx: -2, dy: -3).contains(p) }) {
            editText = hzText(c.edges[l.edge].hz)
            editAt = CGPoint(x: l.rect.midX, y: l.rect.midY)
            editing = .edge(l.edge)
            return
        }
        for b in c.enabledBands {
            let d = geo.dot(c, b)
            if hypot(p.x - d.x, p.y - d.y) <= 11 {
                model.config.bands[b].gainDB = 0
                return
            }
            let label = geo.gainLabel(c, b)
            if label.insetBy(dx: -4, dy: -2).contains(p) {
                editText = String(format: "%.1f", c.bands[b].gainDB)
                editAt = CGPoint(x: label.midX, y: label.midY)
                editing = .gain(b)
                return
            }
        }
    }

    private func commitEdit() {
        guard let target = editing else { return }
        editing = nil
        switch target {
        case .edge(let k):
            if let hz = parseHz(editText) { model.setEdge(k, hz: hz) }
        case .gain(let b):
            if let db = parseDB(editText) { model.config.bands[b].gainDB = (db * 10).rounded() / 10 }
        }
    }

    private func drag(_ geo: GraphGeometry) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragging == nil {
                    dragging = target(at: v.startLocation, geo)
                    if case .gain(let b) = dragging { dragStartDB = model.config.bands[b].gainDB }
                }
                switch dragging {
                case .edge(let k):
                    model.setEdge(k, hz: geo.hz(v.location.x))
                case .gain(let b):
                    let perPoint = (GraphGeometry.topDB - GraphGeometry.bottomDB) / Double(geo.plot.height)
                    let db = dragStartDB - Double(v.translation.height) * perPoint
                    let r = SplitConfig.gainRange
                    let clamped = min(max(db, r.lowerBound), r.upperBound)
                    model.config.bands[b].gainDB = abs(clamped) < 0.4 ? 0 : (clamped * 10).rounded() / 10
                case nil:
                    break
                }
            }
            .onEnded { _ in dragging = nil }
    }
}

private struct GridLayer: View {
    let geo: GraphGeometry
    let pal: Palette

    var body: some View {
        Canvas { ctx, _ in
            let p = geo.plot
            let label = pal.ink.opacity(0.4)
            for hz in [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000] {
                let x = geo.x(hz)
                var path = Path()
                path.move(to: CGPoint(x: x, y: p.minY))
                path.addLine(to: CGPoint(x: x, y: p.maxY))
                ctx.stroke(path, with: .color(pal.ink.opacity(hz == 100 || hz == 1000 || hz == 10000 ? 0.09 : 0.05)), lineWidth: 1)
                ctx.draw(Text(hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))").font(.system(size: 10)).foregroundColor(label),
                         at: CGPoint(x: x, y: p.maxY + 12))
            }
            for db in stride(from: GraphGeometry.topDB, through: GraphGeometry.bottomDB, by: -12) {
                let y = geo.y(db)
                var path = Path()
                path.move(to: CGPoint(x: p.minX, y: y))
                path.addLine(to: CGPoint(x: p.maxX, y: y))
                ctx.stroke(path, with: .color(pal.ink.opacity(db == 0 ? 0.13 : 0.05)), lineWidth: 1)
                ctx.draw(Text(db > 0 ? "+\(Int(db))" : "\(Int(db))").font(.system(size: 10)).foregroundColor(label),
                         at: CGPoint(x: p.minX - 18, y: y))
            }
        }
    }
}

/// The input's spectrum, filled in each band's colour across that band's range.
private struct SpectrumLayer: View {
    @EnvironmentObject var spectrum: SpectrumStore
    let geo: GraphGeometry
    let config: SplitConfig
    let pal: Palette

    var body: some View {
        Canvas { ctx, _ in
            let levels = spectrum.levels
            guard levels.count > 1 else { return }
            let p = geo.plot
            var line = Path()
            for (i, db) in levels.enumerated() {
                let x = p.minX + CGFloat(i) / CGFloat(levels.count - 1) * p.width
                let pt = CGPoint(x: x, y: geo.spectrumY(db))
                if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: p.maxX, y: p.maxY))
            fill.addLine(to: CGPoint(x: p.minX, y: p.maxY))
            fill.closeSubpath()
            let bands = config.enabledBands
            for (i, b) in bands.enumerated() {
                let r = config.range(of: b)
                let x0 = i == 0 ? p.minX : geo.x(r.low)
                let x1 = i == bands.count - 1 ? p.maxX : geo.x(r.high)
                var region = ctx
                region.clip(to: Path(CGRect(x: x0, y: p.minY, width: max(x1 - x0, 0), height: p.height)))
                region.fill(fill, with: .linearGradient(
                    Gradient(colors: [pal.bands[b].opacity(pal.dark ? 0.42 : 0.32), pal.bands[b].opacity(0.05)]),
                    startPoint: CGPoint(x: 0, y: p.minY + p.height * 0.25), endPoint: CGPoint(x: 0, y: p.maxY)))
            }
            ctx.stroke(line, with: .color(pal.ink.opacity(pal.dark ? 0.55 : 0.45)), lineWidth: 1.2)
        }
        .allowsHitTesting(false)
    }
}

/// The bands' responses (including each band's level), the crossover lines
/// with their labels, and the band dots.
private struct CurvesLayer: View {
    let geo: GraphGeometry
    let config: SplitConfig
    let sampleRate: Double
    let pal: Palette
    let highlight: (edge: Int?, band: Int?)
    /// The edge whose label is being typed into (hidden under the editor).
    let editing: Int?

    var body: some View {
        let curves = ResponseCache.shared.curves(config.edges, mask: config.enabledMask, sampleRate: sampleRate)
        Canvas { ctx, _ in
            let p = geo.plot

            // Crossover and edge lines, under the curves.
            for k in config.activeEdges {
                let e = config.edges[k]
                let x = geo.x(e.hz)
                let off = SplitConfig.isOuter(k) && e.slope == 0
                let lit = highlight.edge == k
                var path = Path()
                path.move(to: CGPoint(x: x, y: p.minY - 6))
                path.addLine(to: CGPoint(x: x, y: p.maxY))
                ctx.stroke(path, with: .color(pal.ink.opacity(lit ? 0.7 : off ? 0.12 : 0.3)),
                           style: StrokeStyle(lineWidth: lit ? 1.5 : 1, dash: [4, 4]))
            }

            // Band curves: a soft fill, then the line, kept inside the plot.
            var plotCtx = ctx
            plotCtx.clip(to: Path(CGRect(x: p.minX, y: p.minY - 20, width: p.width, height: p.height + 20)))
            for b in config.enabledBands where b < curves.count {
                let audible = config.isAudible(b)
                let gain = config.bands[b].gainDB
                let color = pal.bands[b]
                var line = Path()
                for (i, db) in curves[b].enumerated() {
                    let pt = CGPoint(x: geo.x(ResponseCache.hz(at: i)), y: geo.y(db + gain))
                    if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
                }
                var fill = line
                fill.addLine(to: CGPoint(x: p.maxX, y: p.maxY))
                fill.addLine(to: CGPoint(x: p.minX, y: p.maxY))
                fill.closeSubpath()
                if audible { plotCtx.fill(fill, with: .color(color.opacity(highlight.band == b ? 0.16 : 0.08))) }
                plotCtx.stroke(line, with: .color(audible ? color : color.opacity(0.35)),
                               style: StrokeStyle(lineWidth: highlight.band == b ? 3 : 2.2, lineJoin: .round,
                                                  dash: audible ? [] : [5, 4]))
            }

            // Band names (Ø when polarity is flipped) and level dots.
            for b in config.enabledBands {
                let color = pal.bands[b]
                let band = config.bands[b]
                let d = geo.dot(config, b)
                let name = SplitConfig.bandNames[b].uppercased() + (band.inverted ? "  Ø" : "")
                ctx.draw(Text(name).font(.system(size: 10, weight: .bold)).kerning(1)
                            .foregroundColor(color.opacity(config.isAudible(b) ? 0.95 : 0.4)),
                         at: CGPoint(x: d.x, y: p.minY + 12))
                let r: CGFloat = highlight.band == b ? 7 : 5.5
                let dot = Path(ellipseIn: CGRect(x: d.x - r, y: d.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(dot, with: .color(config.isAudible(b) ? color : Color.gray))
                ctx.stroke(dot, with: .color(pal.graph.opacity(0.9)), lineWidth: 1.5)
                if highlight.band == b || band.gainDB != 0 {
                    let label = geo.gainLabel(config, b)
                    ctx.draw(Text(dbText(band.gainDB)).font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundColor(pal.ink.opacity(0.85)),
                             at: CGPoint(x: label.midX, y: label.midY))
                }
            }

            // Edge labels along the top.
            for l in geo.edgeLabels(config) where l.edge != editing {
                let lit = highlight.edge == l.edge
                ctx.fill(Path(roundedRect: l.rect, cornerRadius: 9.5), with: .color(pal.ink.opacity(lit ? 0.2 : 0.08)))
                ctx.draw(Text(l.text).font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundColor(pal.ink.opacity(lit ? 1 : 0.8)),
                         at: CGPoint(x: l.rect.midX, y: l.rect.midY))
            }
        }
        .allowsHitTesting(false)
    }
}
