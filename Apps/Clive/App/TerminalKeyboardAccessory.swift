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
    private let send: (Data) -> Void

    init(send: @escaping (Data) -> Void) {
        self.send = send
        super.init(frame: .zero)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        [
            ("↓", "down", "Down", "\u{1b}[B"),
            ("↑", "up", "Up", "\u{1b}[A"),
            ("↵", "enter", "Enter", "\r"),
        ].forEach { title, identifier, label, input in
            let button = TerminalKeyButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(
                for: .systemFont(ofSize: 17), maximumPointSize: 24
            )
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.accessibilityIdentifier = identifier
            button.accessibilityLabel = label
            button.accessibilityValue = input
            button.addTarget(self, action: #selector(pressed(_:)), for: .touchUpInside)
            row.addArrangedSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func pressed(_ sender: UIButton) {
        guard let input = sender.accessibilityValue else { return }
        send(Data(input.utf8))
    }
}

final class TerminalKeyButton: UIButton {
    override var isHighlighted: Bool { didSet { updateAppearance() } }

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
        backgroundColor = isHighlighted ? .systemFill : .clear
        tintColor = .label
        setTitleColor(.label, for: .normal)
    }
}
