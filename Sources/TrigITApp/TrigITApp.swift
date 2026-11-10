// SPDX-License-Identifier: GPL-3.0-or-later

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
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { SetCommands(model: model) }
    }
}

/// File and Edit menu commands for the one open Set.
struct SetCommands: Commands {
    @ObservedObject var model: ShowModel

    var body: some Commands {
        // The attribution is a GPL §7(b) term (see NOTICE): modified versions keep it here.
        CommandGroup(replacing: .appInfo) {
            Button("About TrigIT") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: "TrigIT",
                    .credits: NSAttributedString(
                        string: "Originally created by Jonathan Rikner.\nLicensed under GPL-3.0-or-later.",
                        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]),
                ])
            }
        }
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
            Button("New Song") { model.newSong() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.isShowLocked)
            Button("New Destination") { model.newDestination() }
                .disabled(model.isShowLocked)
            Divider()
            Button("Save As…") { model.chooseAndSaveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Show in Finder") { model.showInFinder() }
                .disabled(model.documentURL == nil)
            Button("Previous Versions…") { model.showingVersions = true }
                .disabled(model.documentURL == nil)
            Divider()
            Menu("Export") {
                Button("grandMA3 Timecode Show…") { model.showingMA3Export = true }
            }
        }
        CommandGroup(before: .toolbar) {
            Button("Show") { model.setMode(.show) }
                .keyboardShortcut("1")
            Button("Edit") { model.setMode(.edit) }
                .keyboardShortcut("2")
                .disabled(model.isShowLocked)
            Divider()
        }
        CommandMenu("Show") {
            Button(model.isArmed ? "Disarm" : "Arm") { model.setArmed(!model.isArmed) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button(model.isShowLocked ? "Turn Off Show Lock" : "Turn On Show Lock") { model.setShowLocked(!model.isShowLocked) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            let simulator = model.source == .simulator || model.backupSource == .simulator
            Button(model.simulator.isPlaying ? "Stop Simulator" : "Play Simulator") {
                if model.simulator.isPlaying { model.stop() } else { model.play() }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!simulator)
        }
        CommandGroup(replacing: .help) {
            Button("TrigIT Help") { NSWorkspace.shared.open(URL(string: "https://github.com/jrikner/TrigIT#readme")!) }
        }
        CommandGroup(before: .windowList) {
            Button("Welcome to TrigIT") { model.showingWelcome = true }
                .disabled(model.isShowLocked)
            Divider()
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
    /// Held for as long as TrigIT runs: see applicationDidFinishLaunching.
    private var timingActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Without this, App Nap slows the 100 Hz clock whenever TrigIT isn't the
        // front app, and timecode showed 230-320 ms dropouts in the background.
        // Idle system sleep is still allowed.
        timingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Following timecode and firing Actions on time")
        NSApp.setActivationPolicy(.regular)
        // One window per Set: no tab bar, whose + would open a second window on the same Set.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Without a bundle (`swift run`) the Dock would show a generic icon.
        if Bundle.main.bundleIdentifier == nil { NSApp.applicationIconImage = AppIcon.image }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Writes any unsaved change before TrigIT quits.
    func applicationWillTerminate(_ notification: Notification) {
        ShowModel.current?.saveNow()
        ShowModel.markQuitCleanly()
    }
}
