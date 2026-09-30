import UIKit

enum TerminalInputControlState: Equatable {
    case compact, keyboard
}

struct TerminalInputControlPolicy {
    private(set) var state: TerminalInputControlState = .compact

    mutating func keyboardChanged(visible: Bool) {
        state = visible ? .keyboard : .compact
    }
}

enum TerminalWheelKey: CaseIterable, Equatable {
    case enter, up, down, left, right

    init(_ direction: ActionWheelDirection) {
        switch direction {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        }
    }

    var input: Data {
        let sequence: String
        switch self {
        case .enter: sequence = "\r"
        case .up: sequence = "\u{1b}[A"
        case .down: sequence = "\u{1b}[B"
        case .right: sequence = "\u{1b}[C"
        case .left: sequence = "\u{1b}[D"
        }
        return Data(sequence.utf8)
    }
}

struct TerminalNearbyArrowPolicy {
    static func key(for displacement: CGPoint) -> TerminalWheelKey? {
        let horizontal = abs(displacement.x)
        let vertical = abs(displacement.y)
        let dominant = max(horizontal, vertical)
        let secondary = min(horizontal, vertical)
        guard dominant >= 28, dominant >= secondary * 1.25 else { return nil }
        if horizontal > vertical { return displacement.x > 0 ? .right : .left }
        return displacement.y > 0 ? .down : .up
    }

    static func accepts(_ point: CGPoint, around button: CGRect, within bounds: CGRect) -> Bool {
        let nearby = button.insetBy(dx: -44, dy: -40).intersection(bounds)
        return nearby.contains(point) && !button.contains(point)
    }
}

/// Fixed terminal navigation inputs hosted in the persistent bottom control bar.
final class TerminalKeyboardAccessory: UIView {
    private enum Modifier: String { case shift, control, option, command }
    private let send: (Data) -> Void
    private let scrollView = UIScrollView()
    private let row = UIStackView()
    private let directionsGroup = UIVisualEffectView(effect: nil)
    private let enterButton = ActionWheelControl(type: .system)
    var wheelChanged: ((ActionWheelPreview?) -> Void)?
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
        directionsGroup.translatesAutoresizingMaskIntoConstraints = false
        directionsGroup.layer.cornerRadius = 28
        directionsGroup.layer.cornerCurve = .continuous
        directionsGroup.clipsToBounds = true
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = true
            directionsGroup.effect = effect
        } else {
            directionsGroup.effect = UIBlurEffect(style: .systemMaterial)
        }
        enterButton.backgroundColor = .white
        enterButton.tintColor = .black
        enterButton.setTitleColor(.black, for: .normal)
        enterButton.accessibilityIdentifier = "enter"
        enterButton.accessibilityLabel = "Enter"
        enterButton.accessibilityValue = "\r"
        enterButton.accessibilityHint = "Tap for Enter. Swipe nearby for arrows, or hold and drag for the wheel."
        enterButton.accessibilityCustomActions = [
            ("Up", TerminalWheelKey.up), ("Down", .down), ("Left", .left), ("Right", .right)
        ].map { name, key in
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                self?.send(key.input)
                return self != nil
            }
        }
        enterButton.setTitle("Enter", for: .normal)
        enterButton.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 15), maximumPointSize: 22)
        enterButton.setContentHuggingPriority(.required, for: .horizontal)
        enterButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        enterButton.translatesAutoresizingMaskIntoConstraints = false
        enterButton.layer.cornerRadius = 28
        enterButton.layer.cornerCurve = .continuous
        enterButton.onPreview = { [weak self] preview in self?.wheelChanged?(preview) }
        enterButton.onResult = { [weak self] result in
            switch result {
            case .primary: self?.send(TerminalWheelKey.enter.input)
            case .direction(let direction): self?.send(TerminalWheelKey(direction).input)
            }
        }
        // The four tiny arrows remain a visual cue; the button is one accessibility element.
        enterButton.setDirectionalCueVisible(true)
        addSubview(scrollView)
        addSubview(directionsGroup)
        scrollView.addSubview(row)
        directionsGroup.contentView.addSubview(enterButton)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor), scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            directionsGroup.centerXAnchor.constraint(equalTo: centerXAnchor),
            directionsGroup.topAnchor.constraint(equalTo: topAnchor),
            directionsGroup.heightAnchor.constraint(equalToConstant: 56),
            // Keep the compact Enter control centered at its intrinsic width.
            directionsGroup.widthAnchor.constraint(equalToConstant: 112),
            // Keep the compact center group tight; the expanded keyboard row
            // does not use this button.
            enterButton.widthAnchor.constraint(equalToConstant: 112),
            enterButton.heightAnchor.constraint(equalToConstant: 56),
            enterButton.centerXAnchor.constraint(equalTo: directionsGroup.contentView.centerXAnchor),
            enterButton.centerYAnchor.constraint(equalTo: directionsGroup.contentView.centerYAnchor),
        ])
        rebuildRow()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setKeyboardVisible(_ visible: Bool) {
        guard expanded != visible else { return }
        if visible {
            cancelWheel()
            wheelChanged?(nil)
        }
        expanded = visible
        rebuildRow()
    }

    var compactEnterButton: UIView { enterButton }
    func cancelWheel() { enterButton.cancelWheel() }
    func sendDirectionalKey(_ key: TerminalWheelKey) {
        guard key != .enter else { return }
        send(key.input)
    }

    static func makeSwipeHint() -> NSAttributedString {
        let text = NSMutableAttributedString(string: "Tap for Enter ")
        func appendSymbol(_ name: String) {
            guard let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)) else { return }
            let attachment = NSTextAttachment(image: image)
            attachment.bounds = CGRect(x: 0, y: -1, width: 10, height: 10)
            text.append(NSAttributedString(attachment: attachment))
        }
        appendSymbol("arrow.turn.down.left")
        text.append(NSAttributedString(string: ", Swipe for arrows  "))
        appendSymbol("arrow.up.and.down.and.arrow.left.and.right")
        return text
    }

    private func rebuildRow() {
        row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }
        scrollView.isHidden = !expanded
        directionsGroup.isHidden = expanded
        enterButton.isHidden = expanded
        guard expanded else {
            return
        }
        let keys: [(String, String, String, String?)] =
            [("Esc", "escape", "Escape", "\u{1b}"), ("⇥", "tab", "Tab", "\t"),
               ("⇧", "shift", "Shift", nil), ("⌃", "control", "Control", nil),
               ("⌥", "option", "Option", nil), ("⌘", "command", "Command", nil),
               ("←", "left", "Left", "\u{1b}[D"), ("↓", "down", "Down", "\u{1b}[B"),
               ("↑", "up", "Up", "\u{1b}[A"), ("→", "right", "Right", "\u{1b}[C"),
               ("C", "c", "C", "c"), (".", "period", "Period", "."), ("/", "slash", "Slash", "/"),
               ("@", "at", "At sign", "@"), ("$", "dollar", "Dollar", "$")]
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
        if activeModifiers.contains(.shift), value == Data("\t".utf8) {
            value = Data("\u{1b}[Z".utf8)
        }
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
