import SwiftUI
import UIKit

/// A native text field with the same hardware-style key row used by terminal sessions.
/// Arrow keys move the insertion point while symbol keys insert literal CLI text.
struct CLITextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        field.adjustsFontForContentSizeCategory = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        context.coordinator.installAccessory(on: field)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CLITextField

        init(_ parent: CLITextField) { self.parent = parent }

        func installAccessory(on field: UITextField) {
            field.inputAccessoryView = TerminalKeyboardAccessory(
                send: { [weak self, weak field] data in self?.handle(data, in: field) },
                command: { _ in },
                onLayoutChanged: { [weak field] in field?.reloadInputViews() }
            )
        }

        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }

        private func handle(_ data: Data, in field: UITextField?) {
            guard let field, let value = String(data: data, encoding: .utf8) else { return }
            switch value {
            case "\u{1b}[D": moveCursor(in: field, by: -1)
            case "\u{1b}[C": moveCursor(in: field, by: 1)
            case "\u{1b}[A": field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.beginningOfDocument)
            case "\u{1b}[B": field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
            default:
                guard let range = field.selectedTextRange else { return }
                field.replace(range, withText: value)
                changed(field)
            }
        }

        private func moveCursor(in field: UITextField, by offset: Int) {
            guard let selection = field.selectedTextRange,
                  let position = field.position(from: selection.start, offset: offset)
            else { return }
            field.selectedTextRange = field.textRange(from: position, to: position)
        }
    }
}
