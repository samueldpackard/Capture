import Cocoa

class CustomWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        self.orderOut(nil)
    }
}
