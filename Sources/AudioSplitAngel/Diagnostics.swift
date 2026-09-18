import AppKit
import CoreAudio
import Foundation
import SplitCore
import SwiftUI

/// Headless checks, run from Terminal:
///
///   AudioSplitAngel --list-devices     every device, its UID, channels and rate
///   AudioSplitAngel --probe            builds a real engine with the built-in speakers
///                                      as every band's output (silent, no input, so no
///                                      microphone prompt), checks callbacks flow,
///                                      rebuilds at a new buffer size, and checks nothing
///                                      is left behind
///   AudioSplitAngel --snapshot FILE    the main window, drawn offscreen to a PNG
///                                      (add --demo for a rig with devices and music playing)
enum Diagnostics {
    static func run(_ args: [String]) -> Int32? {
        setlinebuf(stdout) // show progress live even when piped
        if args.contains("--list-devices") { listDevices(); return 0 }
        if args.contains("--probe") { return probe() }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            return snapshot(to: args[i + 1], demo: args.contains("--demo"))
        }
        return nil
    }

    /// Renders the main window offscreen to a PNG. No audio, no permission prompts.
    static func snapshot(to path: String, demo: Bool) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // no Dock icon
        let model = SplitModel(live: false)
        if demo { stageDemo(model) }
        let root = ContentView()
            .environmentObject(model)
            .environmentObject(model.meters)
            .environmentObject(model.spectrum)
        let hosting = NSHostingView(rootView: root)
        let size = NSSize(width: 1180, height: 800)
        // Borderless so it can sit far off-screen without being pulled back on.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        // A real window-server capture composites exactly as on screen; capturing
        // our own window needs no permission.
        var rep: NSBitmapImageRep?
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                               [.bestResolution, .boundsIgnoreFraming]) {
            rep = NSBitmapImageRep(cgImage: image)
        } else if let cached = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: cached)
            rep = cached
        }
        window.orderOut(nil)
        guard let rep, let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return 1 }
        print("Wrote \(path)")
        return 0
    }

    /// For README pictures: a BlackHole input and a 16-output interface, running,
    /// with something like music playing (a kick, a bassline, chords, hi-hats and air).
    private static func stageDemo(_ model: SplitModel) {
        var c = SplitConfig()
        c.input = Endpoint(deviceUID: "demo.blackhole", deviceName: "BlackHole 64ch", firstChannel: 0, stereo: true)
        for b in c.bands.indices {
            c.bands[b].output = Endpoint(deviceUID: "demo.sapphire", deviceName: "Focusrite Sapphire", firstChannel: b * 2, stereo: true)
        }
        c.bands[0].output.stereo = false
        c.bands[0].gainDB = 2.5
        c.bands[3].gainDB = -3
        model.config = c
        model.showForSnapshot(
            EngineStatus(state: .running, message: "Splitting across 2 devices", sampleRate: 48000, bufferFrames: 64,
                         inputLatencyMs: 1.9, outputLatencyMs: 2.4),
            devices: [
                AudioDeviceInfo(objectID: 0, uid: "demo.blackhole", name: "BlackHole 64ch", inputChannels: 64, outputChannels: 64,
                                transport: kAudioDeviceTransportTypeVirtual, sampleRate: 48000),
                AudioDeviceInfo(objectID: 0, uid: "demo.sapphire", name: "Focusrite Sapphire", inputChannels: 16, outputChannels: 16,
                                transport: kAudioDeviceTransportTypeUSB, sampleRate: 48000),
            ])
        var signal = [Float](repeating: 0, count: 8192)
        var seed: UInt32 = 12345
        func noise() -> Float {
            seed = seed &* 1664525 &+ 1013904223
            return Float(seed >> 8) / Float(1 << 24) * 2 - 1
        }
        var pink: Float = 0
        for i in signal.indices {
            let t = Float(i) / 48000
            pink = 0.985 * pink + 0.12 * noise()
            let kick = 0.5 * sin(2 * .pi * 52 * t) * exp(-t * 6)
            let bass = 0.28 * sin(2 * .pi * 82.4 * t) + 0.12 * sin(2 * .pi * 164.8 * t)
            let chords = 0.09 * (sin(2 * .pi * 329.6 * t) + sin(2 * .pi * 415.3 * t) + sin(2 * .pi * 493.9 * t) + sin(2 * .pi * 987.8 * t))
            let lead = 0.05 * sin(2 * .pi * 1975 * t) + 0.03 * sin(2 * .pi * 3951 * t)
            signal[i] = kick + bass + chords + lead + 0.05 * pink + 0.02 * noise()
        }
        model.spectrum.show(signal: signal, sampleRate: 48000)
        model.meters.show(input: [0.62, 0.58], bands: [[0.71, 0], [0.42, 0.40], [0.25, 0.27], [0.12, 0.11]])
    }

    static func listDevices() {
        let devices = AudioDeviceInfo.all()
        print("\(devices.count) devices\n")
        for d in devices {
            print(d.name)
            print("    in \(d.inputChannels)  out \(d.outputChannels)  \(Int(d.sampleRate)) Hz  \(d.transportName)")
            print("    uid \(d.uid)")
        }
    }

    static func probe() -> Int32 {
        let devices = AudioDeviceInfo.all()
        guard let speakers = devices.first(where: { $0.isBuiltIn && $0.outputChannels >= 2 && $0.inputChannels == 0 })
            ?? devices.first(where: { $0.outputChannels >= 2 && $0.inputChannels == 0 }) else {
            print("No output-only device to probe with.")
            return 1
        }
        print("Probing with \(speakers.name) (silent)…")

        let engine = EngineController()
        var latest = EngineStatus()
        var rebuilds = 0
        engine.onStatus = { status in
            if status.state == .starting { rebuilds += 1 }
            latest = status
            print("  [\(status.state.rawValue)] \(status.message)")
        }

        var config = SplitConfig()
        for b in config.bands.indices {
            config.bands[b].output = Endpoint(deviceUID: speakers.uid, deviceName: speakers.name, firstChannel: 0, stereo: true)
        }
        config.bufferFrames = 64

        engine.update(config: config)
        engine.start()

        func waitForRunning(_ timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if latest.state == .running { return true }
            }
            return false
        }

        func measure(_ seconds: TimeInterval) -> Double {
            let before = sc_engine_callback_count(engine.core)
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            return Double(sc_engine_callback_count(engine.core) - before) / seconds
        }

        var ok = true
        if waitForRunning(6) {
            let rate = measure(1.5)
            let expected = latest.sampleRate / Double(max(latest.bufferFrames, 1))
            print(String(format: "  %.0f callbacks/s at %d frames, %.0f Hz (expected ≈ %.0f); latency ≈ %.1f ms out",
                         rate, latest.bufferFrames, latest.sampleRate, expected, latest.outputLatencyMs))
            if rate < expected * 0.8 { print("  FAIL: callbacks are not keeping up"); ok = false }
            let worst = Double(sc_engine_take_max_process_time(engine.core)) * machTicksToMs()
            print(String(format: "  longest callback: %.3f ms (budget %.2f ms)", worst,
                         Double(latest.bufferFrames) / latest.sampleRate * 1000))
        } else {
            print("  FAIL: engine did not reach running")
            ok = false
        }

        print("Crossover changes while running…")
        for hz in [80.0, 150, 120] {
            config.setEdge(1, hz: hz)
            config.edges[2].slope = config.edges[2].slope == 24 ? 48 : 24
            engine.update(config: config)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        if rebuilds != 1 { print("  FAIL: a crossover change rebuilt the engine"); ok = false }

        print("Rebuilding at 256 frames…")
        config.bufferFrames = 256
        latest.state = .starting
        engine.update(config: config)
        if waitForRunning(6), latest.bufferFrames == 256 {
            let rate = measure(1.0)
            print(String(format: "  %.0f callbacks/s at %d frames", rate, latest.bufferFrames))
            if rate < latest.sampleRate / 256 * 0.8 { ok = false }
        } else {
            print("  FAIL: rebuild did not come back at 256 frames (got \(latest.bufferFrames))")
            ok = false
        }

        let rebuildsBefore = rebuilds
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        if rebuilds != rebuildsBefore { print("  FAIL: engine kept rebuilding while idle"); ok = false }

        engine.shutdown()
        // The HAL publishes the device list asynchronously; give it a moment.
        var leftovers: [String] = []
        let deadline = Date().addingTimeInterval(2)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            leftovers = CA.deviceIDs().compactMap(CA.uid(of:)).filter { $0.hasPrefix(EngineController.aggregateUIDPrefix) }
        } while !leftovers.isEmpty && Date() < deadline
        if !leftovers.isEmpty { print("  FAIL: aggregate device left behind"); ok = false }
        print(ok ? "Probe passed." : "Probe FAILED.")
        return ok ? 0 : 1
    }

    private static func machTicksToMs() -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000
    }
}
