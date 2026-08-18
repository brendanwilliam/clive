import UIKit

/// App-owned hardware-style terminal key row. Modifier state is intentionally local and
/// is reset whenever its owning terminal view is replaced.
final class TerminalKeyboardAccessory: UIInputView {
    private enum Modifier { case shift, control, option, command }
    private var oneShot = Set<Modifier>()
    private var locked = Set<Modifier>()
    private let send: (Data) -> Void
    private let command: (String) -> Void

    init(send: @escaping (Data) -> Void, command: @escaping (String) -> Void) {
        self.send = send; self.command = command
        super.init(frame: .zero, inputViewStyle: .keyboard)
        allowsSelfSizing = true
        backgroundColor = .secondarySystemBackground
        let keys = ["Tab", "Shift", "Control", "Option", "Command", ".", "/", "@", "$", "←", "↓", "↑", "→", "Touch Keyboard"]
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 5; row.distribution = .fillProportionally
        row.translatesAutoresizingMaskIntoConstraints = false
        for title in keys {
            let button = UIButton(type: .system); button.setTitle(title, for: .normal); button.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
            button.accessibilityLabel = title; button.addTarget(self, action: #selector(pressed(_:)), for: .touchUpInside)
            if ["Shift", "Control", "Option", "Command"].contains(title) { button.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))) }
            row.addArrangedSubview(button)
        }
        addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), row.topAnchor.constraint(equalTo: topAnchor, constant: 6), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6), heightAnchor.constraint(greaterThanOrEqualToConstant: 42)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func resetModifiers() { oneShot.removeAll(); locked.removeAll(); refreshModifierButtons() }

    @objc private func pressed(_ sender: UIButton) {
        guard let title = sender.currentTitle else { return }
        if let modifier = modifier(named: title) { toggle(modifier, locked: false); return }
        if title == "Touch Keyboard" { resignFirstResponder(); return }
        let arrows = ["←": "\u{1b}[D", "↓": "\u{1b}[B", "↑": "\u{1b}[A", "→": "\u{1b}[C", "Tab": "\t"]
        var value = arrows[title] ?? title
        if active(.command) { command(value); consumeOneShot(); return }
        if active(.shift), value.count == 1 { value = value.uppercased() }
        if active(.control), let scalar = value.unicodeScalars.first, scalar.value >= 0x40, scalar.value <= 0x7f { value = String(UnicodeScalar(scalar.value & 0x1f)!) }
        if active(.option) { value = "\u{1b}" + value }
        send(Data(value.utf8)); consumeOneShot()
    }
    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let title = (gesture.view as? UIButton)?.currentTitle, let modifier = modifier(named: title) else { return }
        toggle(modifier, locked: true)
    }
    private func modifier(named title: String) -> Modifier? { switch title { case "Shift": .shift; case "Control": .control; case "Option": .option; case "Command": .command; default: nil } }
    private func active(_ modifier: Modifier) -> Bool { oneShot.contains(modifier) || locked.contains(modifier) }
    private func toggle(_ modifier: Modifier, locked shouldLock: Bool) {
        if shouldLock { if locked.contains(modifier) { locked.remove(modifier) } else { locked.insert(modifier); oneShot.remove(modifier) } }
        else if !locked.contains(modifier) { if oneShot.contains(modifier) { oneShot.remove(modifier) } else { oneShot.insert(modifier) } }
        refreshModifierButtons()
    }
    private func consumeOneShot() { oneShot.removeAll(); refreshModifierButtons() }
    private func refreshModifierButtons() { for case let button as UIButton in subviews.flatMap({ $0.subviews }) { if let modifier = modifier(named: button.currentTitle ?? "") { button.isSelected = active(modifier); button.tintColor = button.isSelected ? .systemBlue : .label } } }
}
