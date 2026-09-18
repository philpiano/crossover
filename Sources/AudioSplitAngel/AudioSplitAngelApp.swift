import AppKit
import SwiftUI

@main
struct AudioSplitAngelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = SplitModel()

    init() {
        // Command-line checks run instead of the app (see Diagnostics.swift).
        if let code = Diagnostics.run(CommandLine.arguments) { exit(code) }
    }

    var body: some Scene {
        Window("Audio Split Angel", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.meters)
                .environmentObject(model.spectrum)
        }
        .defaultSize(width: 1180, height: 800)

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: model.status.state == .running ? "waveform.circle.fill" : "waveform.circle")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window must not stop the audio. Quit from the menu bar icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        SplitModel.current?.shutdown()
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: SplitModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = model.status
        Text(s.state == .running ? "Splitting · \(Int(s.sampleRate)) Hz · \(s.bufferFrames) frames" : s.message)
        Divider()
        Button("Open Audio Split Angel") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Restart Audio Engine") { model.engine.restart() }
        Divider()
        Button("Quit Audio Split Angel") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
