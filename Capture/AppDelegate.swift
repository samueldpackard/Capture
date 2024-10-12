import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var viewModel = ContentViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView(viewModel: viewModel)

        // Create the window with a title bar to allow moving
        window = CustomWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 70),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.collectionBehavior = [.fullScreenAuxiliary] // Remove .canJoinAllSpaces
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.orderOut(nil) // Hide the window initially
        window.delegate = self

        // Listen for the notification to show the window
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showWindow), name: Notification.Name("ShowNotionDialog"), object: nil)

        // Observe active space changes
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceDidChange), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    @objc func showWindow() {
        if window.isVisible {
            return
        }
        window.center()
        viewModel.inputText = "" // Clear the input text
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        viewModel.isFocused = true // Focus the text field
    }

    @objc func spaceDidChange(_ notification: Notification) {
        window.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        window.orderOut(nil)
    }
}
