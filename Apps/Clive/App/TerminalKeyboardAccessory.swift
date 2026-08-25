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
    private let compactStack = UIStackView()
    private let directionsGroup = UIVisualEffectView(effect: nil)
    private let directionsStack = UIStackView()
    private let enterButton = TerminalKeyButton(type: .system)
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
        compactStack.axis = .vertical
        compactStack.spacing = 8
        compactStack.translatesAutoresizingMaskIntoConstraints = false
        directionsStack.axis = .vertical
        directionsStack.distribution = .fillEqually
        directionsStack.translatesAutoresizingMaskIntoConstraints = false
        directionsGroup.translatesAutoresizingMaskIntoConstraints = false
        directionsGroup.layer.cornerRadius = 22
        directionsGroup.layer.cornerCurve = .continuous
        directionsGroup.clipsToBounds = true
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = true
            directionsGroup.effect = effect
        } else {
            directionsGroup.effect = UIBlurEffect(style: .systemMaterial)
        }
        enterButton.isPrimary = true
        enterButton.accessibilityIdentifier = "enter"
        enterButton.accessibilityLabel = "Enter"
        enterButton.accessibilityValue = "\r"
        enterButton.setTitle("↵", for: .normal)
        enterButton.titleLabel?.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 28, weight: .medium), maximumPointSize: 34)
        enterButton.titleLabel?.adjustsFontForContentSizeCategory = true
        enterButton.layer.cornerRadius = 22
        enterButton.addTarget(self, action: #selector(pressed(_:)), for: .touchUpInside)
        addSubview(scrollView)
        addSubview(compactStack)
        scrollView.addSubview(row)
        compactStack.addArrangedSubview(directionsGroup)
        compactStack.addArrangedSubview(enterButton)
        directionsGroup.contentView.addSubview(directionsStack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor), scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            compactStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            compactStack.topAnchor.constraint(equalTo: topAnchor),
            compactStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            compactStack.widthAnchor.constraint(equalToConstant: 44),
            directionsGroup.heightAnchor.constraint(equalToConstant: 88),
            enterButton.heightAnchor.constraint(equalToConstant: 44),
            directionsStack.leadingAnchor.constraint(equalTo: directionsGroup.contentView.leadingAnchor),
            directionsStack.trailingAnchor.constraint(equalTo: directionsGroup.contentView.trailingAnchor),
            directionsStack.topAnchor.constraint(equalTo: directionsGroup.contentView.topAnchor),
            directionsStack.bottomAnchor.constraint(equalTo: directionsGroup.contentView.bottomAnchor),
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
        directionsStack.arrangedSubviews.forEach { directionsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        scrollView.isHidden = !expanded
        compactStack.isHidden = expanded
        guard expanded else {
            [
                ("↑", "up", "Up", "\u{1b}[A"),
                ("↓", "down", "Down", "\u{1b}[B"),
            ].forEach { title, identifier, label, input in
                directionsStack.addArrangedSubview(makeButton(title: title, identifier: identifier, label: label, input: input))
            }
            return
        }
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
            let button = makeButton(title: title, identifier: identifier, label: label, input: input)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
            button.isSelected = activeModifiers.contains(where: { $0.rawValue == identifier })
            button.addTarget(self, action: #selector(pressed(_:)), for: .touchUpInside)
            row.addArrangedSubview(button)
        }
    }

    private func makeButton(title: String, identifier: String, label: String, input: String?) -> TerminalKeyButton {
        let button = TerminalKeyButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17), maximumPointSize: 24)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = label
        button.accessibilityValue = input
        button.addTarget(self, action: #selector(pressed(_:)), for: .touchUpInside)
        return button
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
        backgroundColor = isPrimary ? .white : (isHighlighted || isSelected ? .systemFill : .clear)
        // Terminal keys are utility controls. Reserve the app tint for the
        // selected modifier state instead of coloring the entire key row.
        let titleColor: UIColor = isPrimary ? .black : (isSelected ? .tintColor : .label)
        tintColor = titleColor
        setTitleColor(titleColor, for: .normal)
    }
}
