import AppKit
import SwiftUI

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var app = AppModel(libraryFolder: LumenApp.libraryFolder)

    /// Normally ~/Library/Application Support/Lumen. Tests and soak runs use a throwaway folder so they can never touch a real library.
    static var libraryFolder: URL {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("lumen-test-host-\(UUID().uuidString)")
        }
        if let dir = env["LUMEN_LIBRARY_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        return LibraryStore.defaultFolder
    }

    @Environment(\.openWindow) private var openWindow
    private func openMain() { openWindow(id: "main") }

    var body: some Scene {
        Window("Lumen", id: "main") {
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
                Button("Check for Updates…") { Task { await app.updates.checkAndPrompt() } }.disabled(app.volunteerMode)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Show Control Window") { openMain() }.keyboardShortcut("0")
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
                Button(app.outputs.outputsEnabled ? "Disable Outputs…" : "Enable Outputs") {
                    app.toggleOutputs()
                }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(app.volunteerMode)
                Button(app.volunteerMode ? "Exit Volunteer Mode…" : "Volunteer Mode") {
                    if !app.volunteerMode { app.volunteerMode = true }
                }.keyboardShortcut("v", modifiers: [.command, .shift])
                Divider()
                Button("Sync Planning Center") { Task { await app.pco.sync() } }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(app.volunteerMode)
            }
        }

        Settings {
            Group {
                if app.volunteerMode {
                    ContentUnavailableView("Locked in volunteer mode", systemImage: "lock.fill",
                                           description: Text("Exit volunteer mode in the main window (it asks for the PIN) to change settings."))
                } else {
                    SettingsView()
                }
            }
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

    /// Closing the control window must not take the outputs down with it; bring it back from Window ▸ Show Control Window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// ⌘Q (or a stray click) while something is on the outputs asks first, defaulting to Cancel.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app, !app.quitApproved else { return .terminateNow }
        let e = app.engine
        let live = (e.livePresentationID != nil && !e.slideCleared) || e.mediaLayer != nil
        guard live else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "Quit Lumen while something is on screen?"
        a.informativeText = "Every output — projectors, the livestream and the stage display — will go dark."
        a.alertStyle = .critical
        a.addButton(withTitle: "Keep Running")
        a.addButton(withTitle: "Quit Anyway")
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// ProPresenter-style show keys that work anywhere except while typing.
@MainActor
enum KeyboardShortcuts {
    private static var monitor: Any?

    static func install(_ app: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only the main control window drives the show — not sheets, Settings or the editors, where
            // an arrow key or space bar must never change what's on the outputs.
            guard let key = NSApp.keyWindow, key.identifier?.rawValue == OutputManager.mainWindowID, key.sheetParent == nil,
                  key.attachedSheet == nil else { return event }
            if let responder = key.firstResponder, responder is NSText || responder is NSTextView { return event }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            guard !event.isARepeat else { return event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 || event.keyCode == 126 || event.keyCode == 49 ? nil : event }   // a held key must not race through slides
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
