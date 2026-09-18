// Draws Crossover's app icon: the four-band crossover display in miniature.
//
//   swift tools/make_icon.swift Resources/Logo.png
//
// 1024 x 1024, following Apple's macOS icon grid: an 824-point rounded square
// centred on the canvas, with room around it for the Dock's shadow.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Logo.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError() }

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

let bands = [rgb(1.00, 0.38, 0.40), rgb(1.00, 0.72, 0.30), rgb(0.27, 0.85, 0.56), rgb(0.33, 0.65, 1.00)]

// The tile, with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0.07, 0.075, 0.09))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0.13, 0.14, 0.17), rgb(0.045, 0.05, 0.06)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// The plot area inside the tile.
let plot = tile.insetBy(dx: 60, dy: 110).offsetBy(dx: 0, dy: -25)

// Faint grid.
ctx.setStrokeColor(rgb(1, 1, 1, 0.06))
ctx.setLineWidth(3)
for i in 1..<6 {
    let x = plot.minX + plot.width * Double(i) / 6
    ctx.move(to: CGPoint(x: x, y: tile.minY)); ctx.addLine(to: CGPoint(x: x, y: tile.maxY))
}
for i in 1..<4 {
    let y = plot.minY + plot.height * Double(i) / 4
    ctx.move(to: CGPoint(x: tile.minX, y: y)); ctx.addLine(to: CGPoint(x: tile.maxX, y: y))
}
ctx.strokePath()

// Four Linkwitz-Riley bands, crossovers evenly spaced across the width.
// t runs 0...1 across the plot (log frequency); each crossover is at 1/4, 2/4, 3/4.
func lp(_ t: Double, _ c: Double) -> Double { 1 / (1 + pow(pow(10, 3 * (t - c)), 4)) }
func hp(_ t: Double, _ c: Double) -> Double { 1 - lp(t, c) }
let xs = [0.22, 0.5, 0.78]
func response(_ band: Int, _ t: Double) -> Double {
    let edge = 1.0
    switch band {
    case 0: return edge * lp(t, xs[0])
    case 1: return edge * hp(t, xs[0]) * lp(t, xs[1])
    case 2: return edge * hp(t, xs[0]) * hp(t, xs[1]) * lp(t, xs[2])
    default: return edge * hp(t, xs[1]) * hp(t, xs[2])
    }
}
// Level axis: 0 dB near the top, -42 dB at the bottom of the plot. Quieter
// than that runs off the bottom of the tile, as on a real analyser.
func y(_ mag: Double) -> Double {
    let db = max(20 * log10(max(mag, 1e-9)), -90)
    return plot.maxY - (0 - db) / 42 * plot.height
}

let steps = 400
for b in 0..<4 {
    let line = CGMutablePath()
    for i in 0...steps {
        let t = -0.08 + 1.16 * Double(i) / Double(steps)
        let p = CGPoint(x: plot.minX + t * plot.width, y: y(response(b, t)))
        if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
    }
    let fill = line.mutableCopy()!
    fill.addLine(to: CGPoint(x: tile.maxX + 40, y: tile.minY - 40))
    fill.addLine(to: CGPoint(x: tile.minX - 40, y: tile.minY - 40))
    fill.closeSubpath()
    ctx.saveGState()
    ctx.addPath(fill)
    ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: [bands[b].copy(alpha: 0.55)!, bands[b].copy(alpha: 0.0)!] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: plot.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    ctx.restoreGState()

    ctx.addPath(line)
    ctx.setStrokeColor(bands[b])
    ctx.setLineWidth(22)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}

// A dot on top of each band.
for b in 0..<4 {
    let t = [0.06, 0.36, 0.64, 0.94][b]
    let p = CGPoint(x: plot.minX + t * plot.width, y: y(response(b, t)))
    ctx.setFillColor(bands[b])
    ctx.fillEllipse(in: CGRect(x: p.x - 30, y: p.y - 30, width: 60, height: 60))
    ctx.setStrokeColor(rgb(0.05, 0.05, 0.06))
    ctx.setLineWidth(9)
    ctx.strokeEllipse(in: CGRect(x: p.x - 30, y: p.y - 30, width: 60, height: 60))
}
ctx.restoreGState()

// A hairline rim so the tile reads on dark Docks.
ctx.addPath(tilePath)
ctx.setStrokeColor(rgb(1, 1, 1, 0.12))
ctx.setLineWidth(3)
ctx.strokePath()

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: out) as CFURL
let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("Wrote \(out)")
