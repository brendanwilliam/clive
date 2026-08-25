import UIKit

enum TerminalInputControlState: Equatable {
    case compact, keyboard, shortcuts
}

struct TerminalInputControlPolicy {
    private(set) var state: TerminalInputControlState = .compact
    private var restoreKeyboard = false

    mutating func keyboardChanged(visible: Bool) {
        guard state != .shortcuts else { return }
        state = visible ? .keyboard : .compact
    }

    mutating func openShortcuts() {
        restoreKeyboard = state == .keyboard
        state = .shortcuts
    }

    mutating func dismissShortcuts() {
        state = restoreKeyboard ? .keyboard : .compact
        restoreKeyboard = false
    }
}

/// Fixed terminal navigation inputs hosted in the persistent bottom control bar.
final class TerminalKeyboardAccessory: UIView {
    private enum Modifier: String { case shift, control, option, command }
    private let send: (Data) -> Void
    private let scrollView = UIScrollView()
    private let row = UIStackView()
    private var expanded = false
    private var activeModifiers = Set<Modifier>()

    init(send: @escaping (Data) -> Void) {
        self.send = send
        super.init(frame: .zero)

        row.axis = .horizontal
        row.spacing = 7
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.addSubview(row)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor), scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
        rebuildRow()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setKeyboardVisible(_ visible: Bool) {
        guard expanded != visible else { return }
        expanded = visible
        rebuildRow()
    }

    private func rebuildRow() {
        row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }
        let keys: [(String, String, String, String?)] = expanded
            ? [("Esc", "escape", "Escape", "\u{1b}"), ("⇥", "tab", "Tab", "\t"),
               ("⇧", "shift", "Shift", nil), ("⌃", "control", "Control", nil),
               ("⌥", "option", "Option", nil), ("⌘", "command", "Command", nil),
               ("←", "left", "Left", "\u{1b}[D"), ("↓", "down", "Down", "\u{1b}[B"),
               ("↑", "up", "Up", "\u{1b}[A"), ("→", "right", "Right", "\u{1b}[C"),
               (".", "period", "Period", "."), ("/", "slash", "Slash", "/"),
               ("@", "at", "At sign", "@"), ("$", "dollar", "Dollar", "$")]
            : [("↓", "down", "Down", "\u{1b}[B"), ("↑", "up", "Up", "\u{1b}[A"), ("↵", "enter", "Enter", "\r")]
        for (title, identifier, label, input) in keys {
            let button = TerminalKeyButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17), maximumPointSize: 24)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.accessibilityIdentifier = identifier
            button.accessibilityLabel = label
            button.accessibilityValue = input
            button.isPrimary = identifier == "enter" && !expanded
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
            button.isSelected = activeModifiers.contains(where: { $0.rawValue == identifier })
            button.addTarget(self, action: #selector(pressed(_:)), for: .touchUpInside)
            row.addArrangedSubview(button)
        }
    }

    @objc private func pressed(_ sender: UIButton) {
        guard let identifier = sender.accessibilityIdentifier else { return }
        if let modifier = Modifier(rawValue: identifier) {
            if activeModifiers.contains(modifier) { activeModifiers.remove(modifier) } else { activeModifiers.insert(modifier) }
            rebuildRow()
            return
        }
        guard let input = sender.accessibilityValue else { return }
        send(applyModifiers(to: Data(input.utf8)))
    }

    private func applyModifiers(to data: Data) -> Data {
        var value = data
        if activeModifiers.contains(.option) { value.insert(0x1b, at: 0) }
        if activeModifiers.contains(.control), value.count == 1, let byte = value.first, byte >= 0x40, byte <= 0x7f { value = Data([byte & 0x1f]) }
        activeModifiers.removeAll()
        return value
    }
}

final class TerminalKeyButton: UIButton {
    var isPrimary = false { didSet { updateAppearance() } }
    override var isHighlighted: Bool { didSet { updateAppearance() } }
    override var isSelected: Bool { didSet { updateAppearance() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous
        clipsToBounds = true
        updateAppearance()
    }

    private func updateAppearance() {
        backgroundColor = isPrimary ? .systemBlue : (isHighlighted || isSelected ? .systemFill : .clear)
        // Terminal keys are utility controls. Reserve the app tint for the
        // selected modifier state instead of coloring the entire key row.
        let titleColor: UIColor = isPrimary ? .white : (isSelected ? .tintColor : .label)
        tintColor = titleColor
        setTitleColor(titleColor, for: .normal)
    }
}
