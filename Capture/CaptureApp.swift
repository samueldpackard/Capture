import SwiftUI

@main
struct CaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView() // Minimal scene since we're managing the window manually
        }
    }
}
