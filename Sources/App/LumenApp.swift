import AppKit
import SwiftUI

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup("Lumen", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 1200, minHeight: 720)
                .onAppear {
                    delegate.app = app
                    // Unit tests use the app as host; don't open outputs, servers or MIDI ports there.
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    app.start()
                    KeyboardShortcuts.install(app)
                }
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await app.updates.checkAndPrompt() } }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Song") { _ = app.newPresentation(kind: .song) }.keyboardShortcut("n")
                Button("New Presentation") { _ = app.newPresentation(kind: .generic) }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Show") {
                Button("Next Slide") { app.engine.next() }
                Button("Previous Slide") { app.engine.previous() }
                Divider()
                Button("Clear Slide (F1)") { app.engine.clear(.slide) }
                Button("Clear Media (F2)") { app.engine.clear(.media) }
                Button("Clear Props (F3)") { app.engine.clear(.props) }
                Button("Clear Messages (F4)") { app.engine.clear(.messages) }
                Button("Clear All (F5)") { app.engine.clear(.all) }
                Divider()
                Button(app.outputs.outputsEnabled ? "Disable Outputs" : "Enable Outputs") {
                    app.outputs.outputsEnabled.toggle()
                }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button(app.volunteerMode ? "Exit Volunteer Mode…" : "Volunteer Mode") {
                    if !app.volunteerMode { app.volunteerMode = true }
                }.keyboardShortcut("v", modifiers: [.command, .shift])
                Divider()
                Button("Sync Planning Center") { Task { await app.pco.sync() } }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(app)
                .frame(minWidth: 860, minHeight: 600)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var app: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { app?.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// ProPresenter-style show keys that work anywhere except while typing.
@MainActor
enum KeyboardShortcuts {
    private static var monitor: Any?

    static func install(_ app: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let responder = NSApp.keyWindow?.firstResponder, responder is NSText || responder is NSTextView {
                return event
            }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            switch event.keyCode {
            case 124, 125, 49, 121: app.engine.next(); return nil          // → ↓ space pagedown
            case 123, 126, 116: app.engine.previous(); return nil          // ← ↑ pageup
            case 122: app.engine.clear(.slide); return nil                 // F1
            case 120: app.engine.clear(.media); return nil                 // F2
            case 99: app.engine.clear(.props); return nil                  // F3
            case 118: app.engine.clear(.messages); return nil              // F4
            case 96: app.engine.clear(.all); return nil                    // F5
            case 53:                                                        // esc: operator takes over from AI
                if app.listening.followLyrics { app.listening.takeOver(); return nil }
                return event
            default: return event
            }
        }
    }
}
