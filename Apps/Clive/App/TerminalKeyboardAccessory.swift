import UIKit

/// App-owned hardware-style terminal key row. Modifier state is intentionally local and
/// is reset whenever its owning terminal view is replaced.
final class TerminalKeyboardAccessory: UIInputView {
    private enum Modifier { case shift, control, option, command }
    private enum ExpandedPanel { case shortcuts, additionalKeys }
    private var oneShot = Set<Modifier>()
    private var locked = Set<Modifier>()
    private let send: (Data) -> Void
    private let command: (String) -> Void
    private let onLayoutChanged: () -> Void
    private let saveLastCommand: (String, String) -> Bool
    private var buttons: [UIButton] = []
    private var customKeys: [String] = UserDefaults.standard.stringArray(forKey: "com.clive.keyboard.custom-keys") ?? []
    private var shortcuts: [CLIShortcut]
    private let showsShortcutMenu: Bool
    private var lastCommand: String?
    private weak var keyRow: UIStackView?
    private weak var keyCapsule: UIVisualEffectView?
    private var palette: UIView?
    private var expandedPanel: ExpandedPanel?
    private var savedCommand: String?
    private var shortcutSaveError: String?
    private var heightConstraint: NSLayoutConstraint?

    init(shortcuts: [CLIShortcut], showsShortcutMenu: Bool = true, lastCommand: String? = nil, saveLastCommand: @escaping (String, String) -> Bool = { _, _ in false }, send: @escaping (Data) -> Void, command: @escaping (String) -> Void, onLayoutChanged: @escaping () -> Void = {}) {
        self.shortcuts = shortcuts
        self.showsShortcutMenu = showsShortcutMenu
        self.lastCommand = lastCommand
        self.saveLastCommand = saveLastCommand
        self.send = send; self.command = command; self.onLayoutChanged = onLayoutChanged
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .systemGroupedBackground
        let capsule = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.accessibilityIdentifier = "terminalKeyCapsule"
        capsule.layer.cornerRadius = 20
        capsule.layer.cornerCurve = .continuous
        capsule.layer.borderWidth = 1 / UIScreen.main.scale
        capsule.layer.borderColor = UIColor.separator.cgColor
        capsule.clipsToBounds = true
        let scroll = UIScrollView(); scroll.showsHorizontalScrollIndicator = false; scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 7; row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(capsule); capsule.contentView.addSubview(scroll); scroll.addSubview(row)
        let height = heightAnchor.constraint(equalToConstant: 48); heightConstraint = height
        NSLayoutConstraint.activate([
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            capsule.heightAnchor.constraint(equalToConstant: 40),
            scroll.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: capsule.contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: capsule.contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: capsule.contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            height
        ])
        keyCapsule = capsule; keyRow = row; rebuildRow()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        keyCapsule?.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }

    func updateShortcuts(_ shortcuts: [CLIShortcut]) {
        guard shortcuts != self.shortcuts else { return }
        self.shortcuts = shortcuts
        if expandedPanel == .shortcuts { showPanel(.shortcuts) }
    }

    func updateLastCommand(_ command: String?) {
        guard command != lastCommand else { return }
        lastCommand = command
        shortcutSaveError = nil
        if expandedPanel == .shortcuts { showPanel(.shortcuts) }
    }

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
        if action == "keyboard" { togglePanel(.additionalKeys); return }
        if action == "shortcuts" { togglePanel(.shortcuts); return }
        if action == "saveLastCommand" {
            presentShortcutNamePrompt()
            return
        }
        if action.hasPrefix("shortcut:"), let id = UUID(uuidString: String(action.dropFirst(9))), let shortcut = shortcuts.first(where: { $0.id == id }) {
            send(Data((shortcut.command + "\r").utf8)); consumeOneShot(); return
        }
        if action.hasPrefix("special:") || action.hasPrefix("custom:") {
            let value = String(action.dropFirst(action.hasPrefix("special:") ? 8 : 7))
            send(Data(value.utf8)); consumeOneShot(); return
        }
        if let modifier = modifier(named: action) { toggle(modifier, locked: false); return }
        if action == "escape" { send(Data([0x1b])); consumeOneShot(); return }
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
    @objc private func specialKeyHeld(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let action = (gesture.view as? UIButton)?.accessibilityIdentifier, action.hasPrefix("special:") else { return }
        let value = String(action.dropFirst(8))
        guard !customKeys.contains(value), customKeys.count < 8 else { return }
        customKeys.append(value)
        UserDefaults.standard.set(customKeys, forKey: "com.clive.keyboard.custom-keys")
        rebuildRow()
    }
    private func rebuildRow() {
        guard let row = keyRow else { return }
        row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }
        buttons.removeAll()
        if showsShortcutMenu { row.addArrangedSubview(makeShortcutButton()) }
        row.addArrangedSubview(makeButton(title: "⌨", action: "keyboard", label: "Special keys"))
        let keys: [(String, String, String)] = [
            ("Esc", "escape", "Escape"), ("⇥", "tab", "Tab"), ("⇧", "shift", "Shift"), ("⌃", "control", "Control"), ("⌥", "option", "Option"), ("⌘", "command", "Command")
        ]
        for (title, action, label) in keys { row.addArrangedSubview(makeButton(title: title, action: action, label: label)) }
        let remainingKeys = customKeys.map { ($0, "custom:\($0)", "Custom key \($0)") } + [
            ("←", "left", "Left arrow"), ("↓", "down", "Down arrow"), ("↑", "up", "Up arrow"), ("→", "right", "Right arrow"),
            (".", ".", "Period"), ("/", "/", "Slash"), ("@", "@", "At sign"), ("$", "$", "Dollar")
        ]
        for (title, action, label) in remainingKeys { row.addArrangedSubview(makeButton(title: title, action: action, label: label)) }
        refreshModifierButtons()
    }
    private func makeShortcutButton() -> UIButton {
        let button = TerminalKeyButton(type: .system)
        button.setImage(UIImage(systemName: "text.badge.plus"), for: .normal)
        button.accessibilityLabel = "CLI shortcuts"
        button.accessibilityIdentifier = "shortcuts"
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        button.addTarget(self, action: #selector(pressed(_:)), for: .touchUpInside)
        button.isSelected = expandedPanel == .shortcuts
        buttons.append(button)
        return button
    }
    private func makeButton(title: String, action: String, label: String) -> UIButton {
        let button = TerminalKeyButton(type: .system); button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17), maximumPointSize: 24)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityLabel = label; button.accessibilityIdentifier = action; button.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        button.addTarget(self, action: #selector(pressed(_:)), for: .touchUpInside)
        if action == "keyboard" { button.isSelected = expandedPanel == .additionalKeys }
        if ["shift", "control", "option", "command"].contains(action) { button.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))) }
        buttons.append(button); return button
    }
    private func togglePanel(_ panel: ExpandedPanel) {
        if expandedPanel == panel { closePanel() }
        else { showPanel(panel) }
    }

    private func showPanel(_ panelType: ExpandedPanel) {
        guard let keyCapsule else { return }
        palette?.removeFromSuperview()
        expandedPanel = panelType
        let panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial)); panel.translatesAutoresizingMaskIntoConstraints = false
        panel.accessibilityIdentifier = panelType == .shortcuts ? "shortcutsPanel" : "additionalKeysPalette"
        let content = UIStackView(); content.axis = .vertical; content.spacing = 6; content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(makePanelHeader(title: panelType == .shortcuts ? "CLI shortcuts" : "Additional keys"))
        if panelType == .shortcuts { content.addArrangedSubview(makeShortcutsPanel()) }
        else { content.addArrangedSubview(makeAdditionalKeysGrid()) }
        panel.contentView.addSubview(content); insertSubview(panel, at: 0)
        NSLayoutConstraint.activate([panel.leadingAnchor.constraint(equalTo: leadingAnchor), panel.trailingAnchor.constraint(equalTo: trailingAnchor), panel.topAnchor.constraint(equalTo: topAnchor), panel.bottomAnchor.constraint(equalTo: keyCapsule.topAnchor), content.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 14), content.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -14), content.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 8), content.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -8)])
        palette = panel
        heightConstraint?.constant = 226
        rebuildRow()
        invalidateIntrinsicContentSize()
        onLayoutChanged()
    }

    private func closePanel() {
        palette?.removeFromSuperview()
        palette = nil
        expandedPanel = nil
        heightConstraint?.constant = 48
        rebuildRow()
        invalidateIntrinsicContentSize()
        onLayoutChanged()
    }

    private func makePanelHeader(title text: String) -> UIView {
        let header = UIStackView(); header.axis = .horizontal; header.alignment = .center
        let title = UILabel(); title.text = text; title.font = .preferredFont(forTextStyle: .caption1); title.textColor = .secondaryLabel
        header.addArrangedSubview(title)
        return header
    }

    private func makeShortcutsPanel() -> UIView {
        let scroll = UIScrollView(); scroll.alwaysBounceVertical = true; scroll.translatesAutoresizingMaskIntoConstraints = false
        let list = UIStackView(); list.axis = .vertical; list.spacing = 6; list.translatesAutoresizingMaskIntoConstraints = false
        let save = makePanelButton(title: "Save last command", image: "square.and.arrow.down", action: "saveLastCommand")
        save.isEnabled = canSaveLastCommand
        list.addArrangedSubview(save)
        if let shortcutSaveError {
            let error = UILabel(); error.text = shortcutSaveError; error.textColor = .systemRed; error.font = .preferredFont(forTextStyle: .caption1); error.numberOfLines = 0
            list.addArrangedSubview(error)
        }
        let available = shortcuts.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        for shortcut in available {
            list.addArrangedSubview(makePanelButton(title: shortcut.name, image: "terminal", action: "shortcut:\(shortcut.id.uuidString)"))
        }
        if available.isEmpty {
            let empty = UILabel(); empty.text = "No saved shortcuts"; empty.textColor = .secondaryLabel; empty.textAlignment = .center
            list.addArrangedSubview(empty)
        }
        scroll.addSubview(list)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        NSLayoutConstraint.activate([list.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), list.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor), list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), list.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor), list.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)])
        return scroll
    }

    private func presentShortcutNamePrompt() {
        guard let command = normalizedLastCommand, canSaveLastCommand, let presenter = nearestViewController else { return }
        let alert = UIAlertController(title: "Save CLI shortcut", message: command, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Shortcut name"
            field.text = command
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            self?.confirmLastCommandShortcut(name: alert?.textFields?.first?.text ?? "")
        })
        presenter.present(alert, animated: true)
    }

    func confirmLastCommandShortcut(name: String) {
        guard let command = normalizedLastCommand, canSaveLastCommand else { return }
        if saveLastCommand(name, command) {
            savedCommand = command
            shortcutSaveError = nil
        } else {
            shortcutSaveError = "That shortcut name or command already exists."
        }
        if expandedPanel == .shortcuts { showPanel(.shortcuts) }
    }

    private var nearestViewController: UIViewController? {
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }

    private var normalizedLastCommand: String? {
        guard let command = lastCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return nil }
        return command
    }

    private var canSaveLastCommand: Bool {
        guard let command = normalizedLastCommand, command != savedCommand else { return false }
        return !shortcuts.contains { $0.command.trimmingCharacters(in: .whitespacesAndNewlines) == command }
    }

    private func makePanelButton(title: String, image: String, action: String) -> UIButton {
        let button = TerminalKeyButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: image)
        configuration.imagePadding = 8
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        button.configuration = configuration
        button.contentHorizontalAlignment = .leading
        button.accessibilityIdentifier = action
        button.addTarget(self, action: #selector(pressed(_:)), for: .touchUpInside)
        return button
    }

    private func makeAdditionalKeysGrid() -> UIView {
        let values = ["~", "`", "|", "\\", "{", "}", "[", "]", "(", ")", "<", ">", "=", "*", "#", "^", "_", "-", ";", ":"]
        let grid = UIStackView(); grid.axis = .vertical; grid.spacing = 4; grid.distribution = .fillEqually; grid.translatesAutoresizingMaskIntoConstraints = false
        for chunk in values.chunked(into: 5) {
            let line = UIStackView(); line.axis = .horizontal; line.spacing = 4; line.distribution = .fillEqually
            for value in chunk { let button = makeButton(title: value, action: "special:\(value)", label: "Special key \(value)"); button.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(specialKeyHeld(_:)))); line.addArrangedSubview(button) }
            grid.addArrangedSubview(line)
        }
        grid.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return grid
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

enum TerminalKeyPreviewLayout {
    static func frame(source: CGRect, contentSize: CGSize, safeBounds: CGRect) -> CGRect {
        let width = max(54, contentSize.width + 28), height = max(54, contentSize.height + 16)
        var origin = CGPoint(x: source.midX - width / 2, y: source.minY - height - 8)
        origin.x = min(max(origin.x, safeBounds.minX), safeBounds.maxX - width)
        origin.y = min(max(origin.y, safeBounds.minY), safeBounds.maxY - height)
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }
}

final class TerminalKeyButton: UIButton {
    private weak var preview: UILabel?
    override var isHighlighted: Bool {
        didSet { updateKeyAppearance(animated: true) }
    }

    override var isSelected: Bool {
        didSet { updateKeyAppearance(animated: false) }
    }
    override var isEnabled: Bool { didSet { updateKeyAppearance(animated: false) } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureKeyAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureKeyAppearance()
    }

    private func configureKeyAppearance() {
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous
        clipsToBounds = true
        addTarget(self, action: #selector(showPreview), for: .touchDown)
        addTarget(self, action: #selector(hidePreview), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        updateKeyAppearance(animated: false)
    }

    @objc private func showPreview() {
        guard let window, let value = title(for: .normal), !value.isEmpty,
              let action = accessibilityIdentifier,
              !["keyboard", "shortcuts", "shift", "control", "option", "command"].contains(action) else { return }
        let label = UILabel(); label.text = value; label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .title1); label.adjustsFontForContentSizeCategory = true
        label.textColor = .label; label.backgroundColor = .secondarySystemBackground
        label.layer.cornerRadius = 10; label.clipsToBounds = true
        let size = label.sizeThatFits(CGSize(width: 180, height: 100))
        let source = convert(bounds, to: window); let safe = window.bounds.inset(by: window.safeAreaInsets).insetBy(dx: 8, dy: 8)
        label.frame = TerminalKeyPreviewLayout.frame(source: source, contentSize: size, safeBounds: safe)
        window.addSubview(label); preview = label
    }
    @objc private func hidePreview() { preview?.removeFromSuperview() }

    private func updateKeyAppearance(animated: Bool) {
        let changes = {
            self.backgroundColor = !self.isEnabled ? .clear : (self.isHighlighted ? .systemFill : (self.isSelected ? UIColor.systemBlue.withAlphaComponent(0.22) : .clear))
            self.tintColor = !self.isEnabled ? .tertiaryLabel : (self.isSelected ? .systemBlue : .label)
            self.setTitleColor(!self.isEnabled ? .tertiaryLabel : (self.isSelected ? .systemBlue : .label), for: .normal)
            self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
        }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.08, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
