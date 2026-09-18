import AppKit
import SwiftUI

@main
struct CrossoverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = SplitModel()

    init() {
        // Command-line checks run instead of the app (see Diagnostics.swift).
        if let code = Diagnostics.run(CommandLine.arguments) { exit(code) }
    }

    var body: some Scene {
        Window("Crossover", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.meters)
                .environmentObject(model.spectrum)
        }
        .defaultSize(width: 1180, height: 800)
        .commands {
            UndoCommands(model: model)
            CommandGroup(replacing: .appInfo) {
                Button("About Crossover") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: AppDelegate.credits,
                            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]),
                    ])
                }
            }
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: model.status.state == .running ? "waveform.circle.fill" : "waveform.circle")
        }
    }
}

/// Edit › Undo (⌘Z) and Redo (⇧⌘Z). While you're typing in a box they undo the
/// typing; otherwise they step back and forward through every change to the
/// sound: crossovers, slopes, levels, mute, solo, polarity, deleted bands,
/// devices, channels and loaded presets.
struct UndoCommands: Commands {
    @ObservedObject var model: SplitModel

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                if !Self.sendToTextField(#selector(UndoManager.undo)) { model.undo() }
            }
            .keyboardShortcut("z", modifiers: .command)
            Button("Redo") {
                if !Self.sendToTextField(#selector(UndoManager.redo)) { model.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }

    /// If a text box is being edited, let it handle undo itself.
    private static func sendToTextField(_ action: Selector) -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor,
              let manager = editor.undoManager else { return false }
        if action == #selector(UndoManager.undo) {
            guard manager.canUndo else { return false }
            manager.undo()
        } else {
            guard manager.canRedo else { return false }
            manager.redo()
        }
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let credits = "Created by Philip Warda and Soshiant Lak with the instrumental help of Claude Opus 5.0"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.current.apply()
    }

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
        Button("Open Crossover") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Restart Audio Engine") { model.engine.restart() }
        Divider()
        Button("Quit Crossover") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
