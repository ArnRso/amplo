import AppKit
import SwiftUI

@main
struct AmploApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: appDelegate.controller, updates: appDelegate.updates)
        } label: {
            MenuBarIcon(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)

        Window("Diagnostic Amplo", id: "diagnostic") {
            DiagnosticView(controller: appDelegate.controller)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AmploController()
    let updates = UpdateManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.restoreLastState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}
