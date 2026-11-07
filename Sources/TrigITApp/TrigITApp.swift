import AppKit
import SwiftUI

@main
struct TrigITApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ShowModel()

    var body: some Scene {
        WindowGroup("TrigIT") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 520)
        }
        .commands { SetCommands(model: model) }
    }
}

/// File and Edit menu commands for the one open Set.
struct SetCommands: Commands {
    @ObservedObject var model: ShowModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Set…") { model.chooseAndCreateNew() }
                .keyboardShortcut("n")
                .disabled(model.isShowLocked)
            Button("Open Set…") { model.chooseAndOpen() }
                .keyboardShortcut("o")
                .disabled(model.isShowLocked)
            Menu("Open Recent") {
                ForEach(model.recentDocuments, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { model.open(url) }
                }
            }
            .disabled(model.isShowLocked || model.recentDocuments.isEmpty)
            Divider()
            Button("Save As…") { model.chooseAndSaveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Show in Finder") { model.showInFinder() }
                .disabled(model.documentURL == nil)
            Button("Previous Versions…") { model.showingVersions = true }
                .disabled(model.documentURL == nil)
        }
        // Every edit is saved as it happens, so there is no Save command.
        CommandGroup(replacing: .saveItem) {}
        // Undo works on the whole Set, so it also covers what was typed in fields.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.undo() }
                .keyboardShortcut("z")
                .disabled(!model.canUndo || model.isShowLocked)
            Button("Redo") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo || model.isShowLocked)
        }
    }
}

/// Launched with `swift run`, the executable has no app bundle, so make it a
/// regular foreground app with a Dock icon and a focused window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Writes any unsaved change before TrigIT quits.
    func applicationWillTerminate(_ notification: Notification) {
        ShowModel.current?.saveNow()
    }
}
