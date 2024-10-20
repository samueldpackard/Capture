import Cocoa
import SwiftUI

class CustomWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        self.orderOut(nil)
        NotificationCenter.default.post(name: NSNotification.Name("ResetState"), object: nil)
    }
}
