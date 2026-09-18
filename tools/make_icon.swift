// Draws Crossover's app icon: the four crossover bands in miniature, as solid
// overlapping colour on a white tile.
//
//   swift tools/make_icon.swift Resources/Logo.png
//
// 1024 x 1024, following Apple's macOS icon grid: an 824-point rounded square
// centred on the canvas, with room around it for the Dock's shadow.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Logo.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

// The app's light-mode band colours.
let bands = [rgb(0.91, 0.25, 0.29), rgb(0.95, 0.60, 0.06), rgb(0.10, 0.66, 0.40), rgb(0.16, 0.46, 0.93)]

let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// The white tile, with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.28))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(1, 1, 1))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1), rgb(0.95, 0.955, 0.965)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// Four Linkwitz-Riley (24 dB/oct) bands; t runs across the plot in log frequency,
// three decades wide, with the crossovers spread evenly.
let plot = tile.insetBy(dx: 60, dy: 110).offsetBy(dx: 0, dy: -25)
let xs = [0.22, 0.5, 0.78]
func lp(_ t: Double, _ c: Double) -> Double { 1 / (1 + pow(pow(10, 3 * (t - c)), 4)) }
func hp(_ t: Double, _ c: Double) -> Double { 1 - lp(t, c) }
func response(_ band: Int, _ t: Double) -> Double {
    switch band {
    case 0: return lp(t, xs[0])
    case 1: return hp(t, xs[0]) * lp(t, xs[1])
    case 2: return hp(t, xs[0]) * hp(t, xs[1]) * lp(t, xs[2])
    default: return hp(t, xs[0]) * hp(t, xs[1]) * hp(t, xs[2])
    }
}
// 0 dB near the top of the plot, -42 dB at its bottom; then everything is
// brought 25% closer to the bottom of the tile, so the peaks sit lower.
func y(_ mag: Double) -> Double {
    let db = max(20 * log10(max(mag, 1e-9)), -90)
    let y = plot.maxY - (0 - db) / 42 * plot.height
    return tile.minY + (y - tile.minY) * 0.75
}

// Each band as a solid shape; where two overlap, the colours multiply.
ctx.setBlendMode(.multiply)
for b in 0..<4 {
    let shape = CGMutablePath()
    for i in 0...400 {
        let t = -0.08 + 1.16 * Double(i) / 400
        let p = CGPoint(x: plot.minX + t * plot.width, y: y(response(b, t)))
        if i == 0 { shape.move(to: p) } else { shape.addLine(to: p) }
    }
    shape.addLine(to: CGPoint(x: tile.maxX + 40, y: tile.minY - 40))
    shape.addLine(to: CGPoint(x: tile.minX - 40, y: tile.minY - 40))
    shape.closeSubpath()
    ctx.addPath(shape)
    ctx.setFillColor(bands[b].copy(alpha: 0.72)!)
    ctx.fillPath()
}
ctx.restoreGState()

// A hairline rim so the white tile reads on light Docks.
ctx.addPath(tilePath)
ctx.setStrokeColor(rgb(0, 0, 0, 0.08))
ctx.setLineWidth(3)
ctx.strokePath()

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("Wrote \(out)")
