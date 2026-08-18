import UIKit

/// App-owned hardware-style terminal key row. Modifier state is intentionally local and
/// is reset whenever its owning terminal view is replaced.
final class TerminalKeyboardAccessory: UIInputView {
    private enum Modifier { case shift, control, option, command }
    private var oneShot = Set<Modifier>()
    private var locked = Set<Modifier>()
    private let send: (Data) -> Void
    private let command: (String) -> Void
    private var buttons: [UIButton] = []

    init(send: @escaping (Data) -> Void, command: @escaping (String) -> Void) {
        self.send = send; self.command = command
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .secondarySystemBackground
        let keys: [(title: String, action: String, accessibility: String)] = [
            ("⇥", "tab", "Tab"), ("⇧", "shift", "Shift"), ("⌃", "control", "Control"),
            ("⌥", "option", "Option"), ("⌘", "command", "Command"),
            ("←", "left", "Left arrow"), ("↓", "down", "Down arrow"), ("↑", "up", "Up arrow"),
            ("→", "right", "Right arrow"), (".", ".", "Period"), ("/", "/", "Slash"),
            ("@", "@", "At sign"), ("$", "$", "Dollar"), ("⌨", "keyboard", "Hide keyboard")
        ]
        let scroll = UIScrollView(); scroll.showsHorizontalScrollIndicator = false; scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 7; row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        for key in keys {
            let button = UIButton(type: .system); button.setTitle(key.title, for: .normal); button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.accessibilityLabel = key.accessibility; button.accessibilityIdentifier = key.action
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
            button.addTarget(self, action: #selector(pressed(_:)), for: .touchUpInside)
            if ["shift", "control", "option", "command"].contains(key.action) { button.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))) }
            row.addArrangedSubview(button)
            buttons.append(button)
        }
        addSubview(scroll); scroll.addSubview(row)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor), row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8), row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8), row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4), row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4), row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -8), heightAnchor.constraint(equalToConstant: 48)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func resetModifiers() { oneShot.removeAll(); locked.removeAll(); refreshModifierButtons() }

    /// SwiftTerm sends software-keyboard input through its delegate. Apply selected
    /// modifiers here too, so ⌃ then C and ⇧ then ⇥ work as terminal input.
    func transformSoftwareInput(_ data: Data) -> Data? {
        guard !oneShot.isEmpty || !locked.isEmpty else { return data }
        guard data.count == 1, let byte = data.first else { consumeOneShot(); return data }
        if active(.command) { command(String(decoding: [byte], as: UTF8.self)); consumeOneShot(); return nil }
        var output = Data([byte])
        if active(.shift), byte == 0x09 { output = Data("\u{1b}[Z".utf8) }
        else if active(.shift), byte >= 0x61, byte <= 0x7a { output = Data([byte - 0x20]) }
        if active(.control), output.count == 1, let value = output.first, value >= 0x40, value <= 0x7f { output = Data([value & 0x1f]) }
        if active(.option) { output.insert(0x1b, at: 0) }
        consumeOneShot()
        return output
    }

    @objc private func pressed(_ sender: UIButton) {
        guard let action = sender.accessibilityIdentifier else { return }
        if let modifier = modifier(named: action) { toggle(modifier, locked: false); return }
        if action == "keyboard" { resignFirstResponder(); return }
        let keys = ["left": "\u{1b}[D", "down": "\u{1b}[B", "up": "\u{1b}[A", "right": "\u{1b}[C", "tab": "\t"]
        var value = keys[action] ?? action
        if active(.command) { command(value); consumeOneShot(); return }
        if active(.shift), value == "\t" { value = "\u{1b}[Z" }
        if active(.shift), value.count == 1 { value = value.uppercased() }
        if active(.control), let scalar = value.unicodeScalars.first, scalar.value >= 0x40, scalar.value <= 0x7f { value = String(UnicodeScalar(scalar.value & 0x1f)!) }
        if active(.option) { value = "\u{1b}" + value }
        send(Data(value.utf8)); consumeOneShot()
    }
    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let action = (gesture.view as? UIButton)?.accessibilityIdentifier, let modifier = modifier(named: action) else { return }
        toggle(modifier, locked: true)
    }
    private func modifier(named action: String) -> Modifier? { switch action { case "shift": .shift; case "control": .control; case "option": .option; case "command": .command; default: nil } }
    private func active(_ modifier: Modifier) -> Bool { oneShot.contains(modifier) || locked.contains(modifier) }
    private func toggle(_ modifier: Modifier, locked shouldLock: Bool) {
        if shouldLock { if locked.contains(modifier) { locked.remove(modifier) } else { locked.insert(modifier); oneShot.remove(modifier) } }
        else if !locked.contains(modifier) { if oneShot.contains(modifier) { oneShot.remove(modifier) } else { oneShot.insert(modifier) } }
        refreshModifierButtons()
    }
    private func consumeOneShot() { oneShot.removeAll(); refreshModifierButtons() }
    private func refreshModifierButtons() { for button in buttons { if let action = button.accessibilityIdentifier, let modifier = modifier(named: action) { button.isSelected = active(modifier); button.tintColor = button.isSelected ? .systemBlue : .label } } }
}
