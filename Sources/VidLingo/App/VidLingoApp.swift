import AppKit
import SwiftUI

@main
struct VidLingoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = TranslationSessionStore()

    var body: some Scene {
        WindowGroup(AppText.appName) {
            ContentView(session: session)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear {
                    session.loadSavedTranscripts()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appIcon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = appIcon
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
