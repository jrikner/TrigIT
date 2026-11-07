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
}
