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

    func db(_ y: CGFloat) -> Double {
        Self.topDB - Double((y - plot.minY) / plot.height) * (Self.topDB - Self.bottomDB)
    }

    /// The analyser has its own scale: its floor at the bottom, 0 dBFS near the top.
    func spectrumY(_ db: Float) -> CGFloat {
        let lo = SpectrumStore.floorDB, hi = SpectrumStore.ceilingDB + 6
        let t = CGFloat((min(max(db, lo), hi) - lo) / (hi - lo))
        return plot.maxY - t * plot.height
    }

    /// Where a band's gain handle sits across: the middle of its range, in octaves.
    func bandCentreX(_ config: SplitConfig, _ band: Int) -> CGFloat {
        let r = config.range(of: band)
        return x(sqrt(max(r.low, Self.lowHz) * min(r.high, Self.highHz)))
    }
}

/// The response of each band, computed by the engine's own filter design and
/// cached until the crossovers change.
final class ResponseCache {
    static let shared = ResponseCache()
    static let pointCount = 320

    private var key: [EdgeConfig] = []
    private var rate: Double = 0
    private var curves: [[Double]] = []

    func curves(_ edges: [EdgeConfig], sampleRate: Double) -> [[Double]] {
        if edges == key && rate == sampleRate && !curves.isEmpty { return curves }
        let c = edges.map { sc_edge(hz: Float($0.hz), slope: Int32($0.slope)) }
        let octaves = log2(GraphGeometry.highHz / GraphGeometry.lowHz)
        curves = (0..<SplitConfig.bandCount).map { band in
            (0..<Self.pointCount).map { i in
                let hz = GraphGeometry.lowHz * pow(2, octaves * Double(i) / Double(Self.pointCount - 1))
                return c.withUnsafeBufferPointer { sc_band_response_db($0.baseAddress, sampleRate, Int32(band), hz) }
            }
        }
        key = edges
        rate = sampleRate
        return curves
    }

    static func hz(at i: Int) -> Double {
        GraphGeometry.lowHz * pow(GraphGeometry.highHz / GraphGeometry.lowHz, Double(i) / Double(pointCount - 1))
    }
}

/// The big display: the live spectrum of the input, and over it the four bands'
/// crossover curves. Drag a crossover line left or right to move it; drag a
/// band's dot up or down to set its level (double-click it for 0 dB).
struct CrossoverGraph: View {
    @EnvironmentObject var model: SplitModel

    private enum Target: Equatable { case edge(Int), gain(Int) }
    @State private var dragging: Target?
    @State private var hovering: Target?
    @State private var dragStartDB = 0.0

    var body: some View {
        GeometryReader { g in
            let geo = GraphGeometry(size: g.size)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Palette.graph)
                GridLayer(geo: geo)
                SpectrumLayer(geo: geo, edges: model.config.edges)
                CurvesLayer(geo: geo, config: model.config, sampleRate: rate, highlight: highlighted)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
            .contentShape(Rectangle())
            .gesture(drag(geo))
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                if case .gain(let b) = target(at: tap.location, geo) { model.config.bands[b].gainDB = 0 }
            })
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

    /// Band dots first (they're small), then the nearest crossover line or its label.
    private func target(at p: CGPoint, _ geo: GraphGeometry) -> Target? {
        let c = model.config
        for b in 0..<SplitConfig.bandCount {
            let dot = CGPoint(x: geo.bandCentreX(c, b), y: geo.y(c.bands[b].gainDB))
            if hypot(p.x - dot.x, p.y - dot.y) <= 11 { return .gain(b) }
        }
        var best: (k: Int, d: CGFloat)?
        for k in 0..<SplitConfig.edgeCount {
            let d = abs(p.x - geo.x(c.edges[k].hz))
            if d <= 9, d < (best?.d ?? .infinity) { best = (k, d) }
        }
        return best.map { .edge($0.k) }
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
                    model.config.bands[b].gainDB = (min(max(db, r.lowerBound), r.upperBound) * 10).rounded() / 10
                case nil:
                    break
                }
            }
            .onEnded { _ in dragging = nil }
    }
}

private struct GridLayer: View {
    let geo: GraphGeometry

    var body: some View {
        Canvas { ctx, _ in
            let p = geo.plot
            let label = Color.white.opacity(0.38)
            for hz in [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000] {
                let x = geo.x(hz)
                var path = Path()
                path.move(to: CGPoint(x: x, y: p.minY))
                path.addLine(to: CGPoint(x: x, y: p.maxY))
                ctx.stroke(path, with: .color(.white.opacity(hz == 100 || hz == 1000 || hz == 10000 ? 0.09 : 0.05)), lineWidth: 1)
                ctx.draw(Text(hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))").font(.system(size: 10)).foregroundColor(label),
                         at: CGPoint(x: x, y: p.maxY + 12))
            }
            for db in stride(from: GraphGeometry.topDB, through: GraphGeometry.bottomDB, by: -12) {
                let y = geo.y(db)
                var path = Path()
                path.move(to: CGPoint(x: p.minX, y: y))
                path.addLine(to: CGPoint(x: p.maxX, y: y))
                ctx.stroke(path, with: .color(.white.opacity(db == 0 ? 0.13 : 0.05)), lineWidth: 1)
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
    let edges: [EdgeConfig]

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
            for b in 0..<SplitConfig.bandCount {
                let x0 = b == 0 ? p.minX : geo.x(edges[b].hz)
                let x1 = b == SplitConfig.bandCount - 1 ? p.maxX : geo.x(edges[b + 1].hz)
                var region = ctx
                region.clip(to: Path(CGRect(x: x0, y: p.minY, width: max(x1 - x0, 0), height: p.height)))
                region.fill(fill, with: .linearGradient(
                    Gradient(colors: [Palette.bands[b].opacity(0.42), Palette.bands[b].opacity(0.06)]),
                    startPoint: CGPoint(x: 0, y: p.minY + p.height * 0.25), endPoint: CGPoint(x: 0, y: p.maxY)))
            }
            ctx.stroke(line, with: .color(.white.opacity(0.55)), lineWidth: 1.2)
        }
        .allowsHitTesting(false)
    }
}

/// The four bands' responses (including each band's level), the crossover lines
/// with their labels, and the band dots.
private struct CurvesLayer: View {
    let geo: GraphGeometry
    let config: SplitConfig
    let sampleRate: Double
    let highlight: (edge: Int?, band: Int?)

    var body: some View {
        let curves = ResponseCache.shared.curves(config.edges, sampleRate: sampleRate)
        Canvas { ctx, _ in
            let p = geo.plot

            // Crossover and edge lines, under the curves.
            for k in 0..<SplitConfig.edgeCount {
                let e = config.edges[k]
                let x = geo.x(e.hz)
                let off = SplitConfig.isOuter(k) && e.slope == 0
                let lit = highlight.edge == k
                var path = Path()
                path.move(to: CGPoint(x: x, y: p.minY - 6))
                path.addLine(to: CGPoint(x: x, y: p.maxY))
                ctx.stroke(path, with: .color(.white.opacity(lit ? 0.7 : off ? 0.12 : 0.3)),
                           style: StrokeStyle(lineWidth: lit ? 1.5 : 1, dash: [4, 4]))
            }

            // Band curves: a soft fill, then the line, kept inside the plot.
            var plotCtx = ctx
            plotCtx.clip(to: Path(CGRect(x: p.minX, y: p.minY - 20, width: p.width, height: p.height + 20)))
            for b in 0..<SplitConfig.bandCount {
                guard b < curves.count else { continue }
                let audible = config.isAudible(b)
                let gain = config.bands[b].gainDB
                let color = Palette.bands[b]
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

            // Band names and level dots.
            for b in 0..<SplitConfig.bandCount {
                let x = geo.bandCentreX(config, b)
                let color = Palette.bands[b]
                let band = config.bands[b]
                ctx.draw(Text(SplitConfig.bandNames[b].uppercased()).font(.system(size: 10, weight: .bold)).kerning(1)
                            .foregroundColor(color.opacity(config.isAudible(b) ? 0.95 : 0.4)),
                         at: CGPoint(x: x, y: p.minY + 12))
                let y = geo.y(band.gainDB)
                let r: CGFloat = highlight.band == b ? 7 : 5.5
                let dot = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                ctx.fill(dot, with: .color(config.isAudible(b) ? color : Color.gray))
                ctx.stroke(dot, with: .color(.black.opacity(0.6)), lineWidth: 1.5)
                if highlight.band == b || band.gainDB != 0 {
                    ctx.draw(Text(dbText(band.gainDB)).font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundColor(.white.opacity(0.85)),
                             at: CGPoint(x: x, y: y - 15))
                }
            }

            // Edge labels along the top, pushed apart if they'd overlap.
            var labels: [(k: Int, x: CGFloat, text: String)] = (0..<SplitConfig.edgeCount).map { k in
                let e = config.edges[k]
                let off = SplitConfig.isOuter(k) && e.slope == 0
                return (k, geo.x(e.hz), off ? "off" : hzText(e.hz))
            }
            let width: CGFloat = 62
            for i in 1..<labels.count where labels[i].x - labels[i - 1].x < width + 4 {
                labels[i].x = labels[i - 1].x + width + 4
            }
            for i in stride(from: labels.count - 1, through: 0, by: -1) {
                let limit = i == labels.count - 1 ? p.maxX - width / 2 + 6 : labels[i + 1].x - width - 4
                labels[i].x = min(labels[i].x, limit)
            }
            for l in labels {
                let lit = highlight.edge == l.k
                let rect = CGRect(x: l.x - width / 2, y: 7, width: width, height: 19)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 9.5), with: .color(.white.opacity(lit ? 0.22 : 0.09)))
                ctx.draw(Text(l.text).font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundColor(.white.opacity(lit ? 1 : 0.8)),
                         at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }
        .allowsHitTesting(false)
    }
}
