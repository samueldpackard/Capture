import SwiftUI

struct NonDroppableTextField: NSViewRepresentable {
    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NonDroppableTextField

        init(_ parent: NonDroppableTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            parent.text = (obj.object as? NSTextField)?.stringValue ?? ""
        }
    }

    @Binding var text: String
    var placeholder: String
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = CustomNSTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.isEditable = true
        textField.isBordered = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.font = NSFont.systemFont(ofSize: 24)
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.commit)
        textField.refusesFirstResponder = false

        // Disable drag-and-drop
        textField.registerForDraggedTypes([])

        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = text
    }
}

extension NonDroppableTextField.Coordinator {
    @objc func commit() {
        parent.onCommit()
    }
}

// Custom NSTextField that allows drag events to pass through
class CustomNSTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else {
            return super.hitTest(point)
        }

        if event.type == .leftMouseDragged || event.type == .rightMouseDragged || event.type == .otherMouseDragged || event.type == .mouseMoved {
            return nil
        }

        return super.hitTest(point)
    }
}
