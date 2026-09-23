import CliveCore
import SwiftTerm
import SwiftUI

extension Notification.Name {
    static let terminalKeyboardDismissRequested = Notification.Name("clive.terminalKeyboardDismissRequested")
    static let terminalKeyboardRestoreRequested = Notification.Name("clive.terminalKeyboardRestoreRequested")
}

struct TerminalSurfaceView: UIViewRepresentable {
    let session: SessionClient?
    let accessibilityIdentifier: String
    let isSelected: Bool
    let shortcuts: [CLIShortcut]
    let terminalTheme: TerminalThemePreset
    let customTerminalForeground: TerminalColorPreference
    let customTerminalBackground: TerminalColorPreference
    let customTerminalPalette: [TerminalColorPreference]
    let openDrawer: () -> Void
    let createTerminal: () -> Void
    let selectAdjacentTerminal: (Bool) -> Void
    let runShortcut: (CLIShortcut) -> Bool
    let manageShortcuts: () -> Void
    let previewOutput: String?
    let previewBoundaries: Bool

    init(
        session: SessionClient?,
        accessibilityIdentifier: String,
        isSelected: Bool,
        shortcuts: [CLIShortcut],
        terminalTheme: TerminalThemePreset = .cliveDark,
        customTerminalForeground: TerminalColorPreference = .white,
        customTerminalBackground: TerminalColorPreference = .black,
        customTerminalPalette: [TerminalColorPreference] = TerminalColorPreference.cliveANSIPalette,
        openDrawer: @escaping () -> Void,
        createTerminal: @escaping () -> Void = {},
        selectAdjacentTerminal: @escaping (Bool) -> Void,
        runShortcut: @escaping (CLIShortcut) -> Bool,
        manageShortcuts: @escaping () -> Void,
        previewOutput: String? = nil,
        previewBoundaries: Bool = false
    ) {
        self.session = session
        self.accessibilityIdentifier = accessibilityIdentifier
        self.isSelected = isSelected
        self.shortcuts = shortcuts
        self.terminalTheme = terminalTheme
        self.customTerminalForeground = customTerminalForeground
        self.customTerminalBackground = customTerminalBackground
        self.customTerminalPalette = customTerminalPalette
        self.openDrawer = openDrawer
        self.createTerminal = createTerminal
        self.selectAdjacentTerminal = selectAdjacentTerminal
        self.runShortcut = runShortcut
        self.manageShortcuts = manageShortcuts
        self.previewOutput = previewOutput
        self.previewBoundaries = previewBoundaries
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            session: session,
            shortcuts: shortcuts,
            openDrawer: openDrawer,
            createTerminal: createTerminal,
            selectAdjacentTerminal: selectAdjacentTerminal,
            runShortcut: runShortcut,
            manageShortcuts: manageShortcuts
        )
    }

    func makeUIView(context: Context) -> TerminalSurfaceContainer {
        let container = TerminalSurfaceContainer()
        container.setPreviewBoundaries(previewBoundaries)
        let terminal = container.terminal
        terminal.terminalDelegate = context.coordinator
        // SwiftTerm installs its own TerminalAccessory by default. Clive owns the
        // terminal key toolbar, so do not stack SwiftTerm's accessory above it.
        terminal.inputAccessoryView = nil
        terminal.linkReporting = .implicit
        terminal.linkHighlightMode = .hoverWithModifier
        context.coordinator.applyTerminalStyle(resolvedTerminalStyle, to: terminal)
        terminal.accessibilityIdentifier = accessibilityIdentifier
        terminal.accessibilityLabel = "Terminal"
        terminal.accessibilityValue = isSelected ? "Selected" : "Not selected"
        terminal.keyboardDismissMode = TerminalSurfaceConfiguration.keyboardDismissMode
        terminal.scrollsToTop = TerminalSurfaceConfiguration.scrollsToTop
        context.coordinator.install(on: container)
        if let previewOutput {
            terminal.feed(byteArray: ArraySlice(("\u{1b}[2 q" + previewOutput).utf8))
        } else if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let fixtureOutput = (1...80).map { $0 == 80 ? "https://example.com" : "fixture line \($0)" }.joined(separator: "\r\n")
            terminal.feed(byteArray: ArraySlice(("\u{1b}[2 q" + fixtureOutput).utf8))
        }
        session?.onOutput = { [weak terminal, weak session] data, generation in DispatchQueue.main.async {
            guard generation == session?.currentGeneration else { return }
            terminal?.feed(byteArray: ArraySlice(data))
        } }
        return container
    }

    func updateUIView(_ uiView: TerminalSurfaceContainer, context: Context) {
        context.coordinator.session = session
        context.coordinator.shortcuts = shortcuts
        context.coordinator.openDrawer = openDrawer
        context.coordinator.createTerminal = createTerminal
        context.coordinator.selectAdjacentTerminal = selectAdjacentTerminal
        context.coordinator.runShortcut = runShortcut
        context.coordinator.manageShortcuts = manageShortcuts
        context.coordinator.applyTerminalStyle(resolvedTerminalStyle, to: uiView.terminal)
        uiView.configureShortcutMenu(
            shortcuts,
            run: runShortcut,
            manage: manageShortcuts
        )
        uiView.setPreviewBoundaries(previewBoundaries)
        uiView.terminal.accessibilityIdentifier = accessibilityIdentifier
        uiView.terminal.accessibilityValue = isSelected ? "Selected" : "Not selected"
    }

    private var resolvedTerminalStyle: TerminalThemeStyle {
        TerminalSurfaceConfiguration.style(
            for: terminalTheme,
            customForeground: customTerminalForeground,
            customBackground: customTerminalBackground,
            customPalette: customTerminalPalette
        )
    }

    final class Coordinator: NSObject, TerminalViewDelegate, @unchecked Sendable {
        var session: SessionClient?
        var shortcuts: [CLIShortcut]
        var openDrawer: () -> Void
        var createTerminal: () -> Void
        var selectAdjacentTerminal: (Bool) -> Void
        var runShortcut: (CLIShortcut) -> Bool
        var manageShortcuts: () -> Void
        private weak var container: TerminalSurfaceContainer?
        private var accessory: TerminalKeyboardAccessory?
        private var edgeObserver: TerminalLeftEdgeObserver?
        private var rightEdgeObserver: TerminalRightEdgeObserver?
        private var horizontalSwitchObserver: TerminalHorizontalSwitchObserver?
        private var appliedTerminalStyle: TerminalThemeStyle?

        init(
            session: SessionClient?,
            shortcuts: [CLIShortcut],
            openDrawer: @escaping () -> Void,
            createTerminal: @escaping () -> Void,
            selectAdjacentTerminal: @escaping (Bool) -> Void,
            runShortcut: @escaping (CLIShortcut) -> Bool,
            manageShortcuts: @escaping () -> Void
        ) {
            self.session = session
            self.shortcuts = shortcuts
            self.openDrawer = openDrawer
            self.createTerminal = createTerminal
            self.selectAdjacentTerminal = selectAdjacentTerminal
            self.runShortcut = runShortcut
            self.manageShortcuts = manageShortcuts
        }

        @MainActor func install(on container: TerminalSurfaceContainer) {
            self.container = container
            let accessory = TerminalKeyboardAccessory(send: { [weak self] data in self?.sendInput(data) })
            self.accessory = accessory
            container.installKeyRow(accessory)
            container.onKeyboardRequested = { [weak container] in _ = container?.terminal.becomeFirstResponder() }
            container.onKeyboardDismissRequested = { [weak container] in _ = container?.terminal.resignFirstResponder() }
            container.configureShortcutMenu(
                shortcuts,
                run: runShortcut,
                manage: manageShortcuts
            )
            edgeObserver = TerminalLeftEdgeObserver.install(on: container.terminal) { [weak self] in self?.openDrawer() }
            rightEdgeObserver = TerminalRightEdgeObserver.install(on: container.terminal) { [weak self] in self?.createTerminal() }
            horizontalSwitchObserver = TerminalHorizontalSwitchObserver.install(on: container.terminal) { [weak self] forward in
                self?.selectAdjacentTerminal(forward)
            }
        }

        @MainActor func applyTerminalStyle(_ style: TerminalThemeStyle, to terminal: TerminalView) {
            guard appliedTerminalStyle != style else { return }
            TerminalSurfaceConfiguration.apply(style, to: terminal)
            appliedTerminalStyle = style
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let input = Data(data)
            MainActor.assumeIsolated {
                sendInput(input)
            }
        }
        @MainActor private func sendInput(_ data: Data) { session?.sendInput(data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0, newCols <= Int(UInt16.max), newRows <= Int(UInt16.max) else { return }
            session?.resize(TerminalSize(columns: UInt16(newCols), rows: UInt16(newRows)))
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = TerminalLinkPolicy.destination(for: link) else { return }
            MainActor.assumeIsolated { UIApplication.shared.open(url) }
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

@MainActor final class TerminalSurfaceContainer: UIView {
    let terminal = TerminalView(frame: .zero)
    var onKeyboardRequested: (() -> Void)?
    var onKeyboardDismissRequested: (() -> Void)?
    private let controls = TerminalBottomControls()
    private var terminalBottomToKeyboardGuide: NSLayoutConstraint!
    private var terminalBottomToControls: NSLayoutConstraint!
    private var controlsBottomToKeyboardGuide: NSLayoutConstraint!

    #if DEBUG
    private let previewTintView = UIView()
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        #if DEBUG
        previewTintView.translatesAutoresizingMaskIntoConstraints = false
        // Deliberately stronger than the boundary tint so the preview-only
        // terminal region is easy to distinguish from the surrounding layout.
        previewTintView.backgroundColor = UIColor.systemCyan.withAlphaComponent(0.14)
        previewTintView.isHidden = true
        previewTintView.isUserInteractionEnabled = false
        addSubview(previewTintView)
        #endif
        addSubview(controls)
        let focusGesture = UITapGestureRecognizer(target: self, action: #selector(focusTerminal))
        focusGesture.cancelsTouchesInView = false
        terminal.addGestureRecognizer(focusGesture)
        terminalBottomToKeyboardGuide = terminal.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)
        terminalBottomToControls = terminal.bottomAnchor.constraint(
            equalTo: controls.topAnchor,
            constant: -TerminalSurfaceConfiguration.bottomControlTopSpacing
        )
        controlsBottomToKeyboardGuide = controls.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor, constant: -(TerminalSurfaceConfiguration.bottomControlSafeAreaSpacing - 2))
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor), terminal.leadingAnchor.constraint(equalTo: leadingAnchor), terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Keep the terminal above the complete bottom control row in both
            // compact and keyboard modes. Compact controls no longer float over
            // terminal output.
            terminalBottomToControls,
            controls.leadingAnchor.constraint(equalTo: leadingAnchor), controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlsBottomToKeyboardGuide, controls.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        #if DEBUG
        NSLayoutConstraint.activate([
            previewTintView.topAnchor.constraint(equalTo: terminal.topAnchor),
            previewTintView.leadingAnchor.constraint(equalTo: terminal.leadingAnchor),
            previewTintView.trailingAnchor.constraint(equalTo: terminal.trailingAnchor),
            previewTintView.bottomAnchor.constraint(equalTo: terminal.bottomAnchor),
        ])
        #endif
        controls.onKeyboard = { [weak self] shown in shown ? self?.onKeyboardDismissRequested?() : self?.onKeyboardRequested?() }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dismissKeyboardRequested), name: .terminalKeyboardDismissRequested, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restoreKeyboardRequested), name: .terminalKeyboardRestoreRequested, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func focusTerminal() {
        _ = terminal.becomeFirstResponder()
    }

    @objc private func restoreKeyboardRequested() {
        onKeyboardRequested?()
    }

    @objc private func dismissKeyboardRequested() {
        onKeyboardDismissRequested?()
    }

    func installKeyRow(_ row: TerminalKeyboardAccessory) { controls.installKeyRow(row) }

    func setPreviewBoundaries(_ visible: Bool) {
        controls.setPreviewBoundaries(visible)
        #if DEBUG
        previewTintView.isHidden = !visible
        #endif
    }

    func configureShortcutMenu(
        _ shortcuts: [CLIShortcut],
        run: @escaping (CLIShortcut) -> Bool,
        manage: @escaping () -> Void
    ) {
        controls.configureShortcutMenu(shortcuts: shortcuts, run: run, manage: manage)
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let window else { return }
        let keyboardVisible = window.convert(frame, from: nil).intersects(window.bounds) && frame.minY < window.bounds.height
        setKeyboardVisible(keyboardVisible)
    }

    private func setKeyboardVisible(_ visible: Bool) {
        controls.setKeyboardVisible(visible)
        controlsBottomToKeyboardGuide.constant = visible ? 0 : -(TerminalSurfaceConfiguration.bottomControlSafeAreaSpacing - 2)
        if visible {
            terminalBottomToKeyboardGuide.isActive = false
            terminalBottomToControls.isActive = true
        } else {
            terminalBottomToKeyboardGuide.isActive = false
            terminalBottomToControls.isActive = true
        }
    }
}

@MainActor final class TerminalBottomControls: UIView {
    private static let shortcutSymbolName = "chevron.left.forwardslash.chevron.right"
    var onKeyboard: ((Bool) -> Void)?
    private let keyboardButton = UIButton(type: .system)
    let shortcutButton = UIButton(type: .system)
    private let keyboardGroup = UIVisualEffectView(effect: nil)
    private let keyRowGroup = UIVisualEffectView(effect: nil)
    private let shortcutsGroup = UIVisualEffectView(effect: nil)
    private let rowHost = UIView()
    private var compactKeyRowTrailing: NSLayoutConstraint!
    private var compactKeyRowLeading: NSLayoutConstraint!
    private var expandedKeyRowLeading: NSLayoutConstraint!
    private var expandedKeyRowTrailing: NSLayoutConstraint!
    private var controlsHeight: NSLayoutConstraint!
    private var keyRowHeight: NSLayoutConstraint!
    private var keyRow: TerminalKeyboardAccessory?
    private var keyboardVisible = false
    private var policy = TerminalInputControlPolicy()

    #if DEBUG
    private let previewBoundaryLabel = UILabel()
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        [keyboardGroup, keyRowGroup, shortcutsGroup].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.layer.cornerRadius = 22
            $0.layer.cornerCurve = .continuous
            $0.clipsToBounds = $0 !== keyRowGroup
            addSubview($0)
        }
        keyboardButton.accessibilityIdentifier = "terminal-keyboard-button"
        shortcutButton.accessibilityIdentifier = "terminal-shortcuts-button"
        shortcutButton.accessibilityLabel = "Shortcuts"
        keyboardButton.addTarget(self, action: #selector(toggleKeyboard), for: .touchUpInside)
        shortcutButton.showsMenuAsPrimaryAction = true
        keyboardButton.translatesAutoresizingMaskIntoConstraints = false
        shortcutButton.translatesAutoresizingMaskIntoConstraints = false
        rowHost.translatesAutoresizingMaskIntoConstraints = false
        keyboardGroup.contentView.addSubview(keyboardButton)
        keyRowGroup.contentView.addSubview(rowHost)
        shortcutsGroup.contentView.addSubview(shortcutButton)
        NSLayoutConstraint.activate([
            shortcutsGroup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), shortcutsGroup.widthAnchor.constraint(equalToConstant: 44), shortcutsGroup.heightAnchor.constraint(equalToConstant: 44), shortcutsGroup.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            keyboardGroup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), keyboardGroup.widthAnchor.constraint(equalToConstant: 44), keyboardGroup.heightAnchor.constraint(equalToConstant: 44), keyboardGroup.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            keyboardButton.leadingAnchor.constraint(equalTo: keyboardGroup.contentView.leadingAnchor), keyboardButton.trailingAnchor.constraint(equalTo: keyboardGroup.contentView.trailingAnchor), keyboardButton.topAnchor.constraint(equalTo: keyboardGroup.contentView.topAnchor), keyboardButton.bottomAnchor.constraint(equalTo: keyboardGroup.contentView.bottomAnchor),
            shortcutButton.leadingAnchor.constraint(equalTo: shortcutsGroup.contentView.leadingAnchor), shortcutButton.trailingAnchor.constraint(equalTo: shortcutsGroup.contentView.trailingAnchor), shortcutButton.topAnchor.constraint(equalTo: shortcutsGroup.contentView.topAnchor), shortcutButton.bottomAnchor.constraint(equalTo: shortcutsGroup.contentView.bottomAnchor),
            rowHost.leadingAnchor.constraint(equalTo: keyRowGroup.contentView.leadingAnchor), rowHost.trailingAnchor.constraint(equalTo: keyRowGroup.contentView.trailingAnchor), rowHost.topAnchor.constraint(equalTo: keyRowGroup.contentView.topAnchor), rowHost.bottomAnchor.constraint(equalTo: keyRowGroup.contentView.bottomAnchor),
        ])
        compactKeyRowLeading = keyRowGroup.leadingAnchor.constraint(equalTo: shortcutsGroup.trailingAnchor, constant: 4)
        compactKeyRowTrailing = keyRowGroup.trailingAnchor.constraint(equalTo: keyboardGroup.leadingAnchor, constant: -4)
        expandedKeyRowLeading = keyRowGroup.leadingAnchor.constraint(equalTo: shortcutsGroup.trailingAnchor, constant: 4)
        expandedKeyRowTrailing = keyRowGroup.trailingAnchor.constraint(equalTo: keyboardGroup.leadingAnchor, constant: -4)
        controlsHeight = heightAnchor.constraint(equalToConstant: 144)
        keyRowHeight = keyRowGroup.heightAnchor.constraint(equalToConstant: 140)
        NSLayoutConstraint.activate([
            keyRowGroup.centerYAnchor.constraint(equalTo: centerYAnchor), keyRowHeight,
            compactKeyRowLeading,
            compactKeyRowTrailing,
            controlsHeight,
        ])
        shortcutButton.setImage(
            UIImage(
                systemName: Self.shortcutSymbolName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            ),
            for: .normal
        )
        keyboardButton.tintColor = .white
        shortcutButton.tintColor = .white
        [keyboardGroup, keyRowGroup, shortcutsGroup].forEach { group in
            if #available(iOS 26.0, *) {
                let effect = UIGlassEffect(style: .regular)
                effect.isInteractive = true
                group.effect = effect
            } else {
                group.effect = UIBlurEffect(style: .systemMaterial)
            }
        }
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func installKeyRow(_ row: TerminalKeyboardAccessory) {
        keyRow = row; row.translatesAutoresizingMaskIntoConstraints = false; rowHost.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: rowHost.leadingAnchor), row.trailingAnchor.constraint(equalTo: rowHost.trailingAnchor),
            row.topAnchor.constraint(equalTo: rowHost.topAnchor), row.bottomAnchor.constraint(equalTo: rowHost.bottomAnchor),
        ])
    }

    #if DEBUG
    func setPreviewBoundaries(_ visible: Bool) {
        layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.9).cgColor
        layer.borderWidth = visible ? 1 : 0
        guard visible, previewBoundaryLabel.superview == nil else { return }

        previewBoundaryLabel.translatesAutoresizingMaskIntoConstraints = false
        previewBoundaryLabel.text = "Bottom buttons"
        previewBoundaryLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        previewBoundaryLabel.textColor = .systemCyan
        previewBoundaryLabel.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        previewBoundaryLabel.layer.cornerRadius = 4
        previewBoundaryLabel.layer.masksToBounds = true
        previewBoundaryLabel.isUserInteractionEnabled = false
        addSubview(previewBoundaryLabel)
        NSLayoutConstraint.activate([
            previewBoundaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            previewBoundaryLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        ])
    }
    #else
    func setPreviewBoundaries(_: Bool) {}
    #endif

    func setKeyboardVisible(_ visible: Bool) { keyboardVisible = visible; policy.keyboardChanged(visible: visible); updateAppearance() }
    func configureShortcutMenu(
        shortcuts: [CLIShortcut],
        run: @escaping (CLIShortcut) -> Bool,
        manage: @escaping () -> Void
    ) {
        let shortcutActions = shortcuts.map { shortcut in
            let command = shortcut.command.trimmingCharacters(in: .whitespacesAndNewlines)
            let action = UIAction(
                title: shortcut.name.isEmpty ? "Unnamed shortcut" : shortcut.name,
                image: UIImage(systemName: Self.shortcutSymbolName),
                attributes: command.isEmpty ? .disabled : []
            ) { _ in
                _ = run(shortcut)
            }
            action.subtitle = ShortcutCommandPresentation.subtitle(for: command)
            return action
        }
        let settings = UIAction(
            title: "Settings",
            image: UIImage(systemName: "gearshape")
        ) { _ in
            manage()
        }
        shortcutButton.menu = UIMenu(children: shortcutActions + [settings])
    }

    @objc private func toggleKeyboard() { onKeyboard?(keyboardVisible) }
    var keyboardControlFrame: CGRect { keyboardGroup.frame }
    var keyRowControlFrame: CGRect { keyRowGroup.frame }
    var shortcutsControlFrame: CGRect { shortcutsGroup.frame }
    var isKeyboardControlVisible: Bool { !keyboardGroup.isHidden }
    var isKeyRowControlVisible: Bool { !keyRowGroup.isHidden }
    var isShortcutsControlVisible: Bool { !shortcutsGroup.isHidden }

    private func updateAppearance() {
        keyboardButton.setImage(UIImage(systemName: keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard"), for: .normal)
        keyboardButton.accessibilityLabel = keyboardVisible ? "Hide keyboard" : "Show keyboard"
        let expanded = policy.state == .keyboard
        let compact = policy.state == .compact
        keyboardButton.isHidden = false
        keyboardGroup.isHidden = false
        keyRow?.setKeyboardVisible(expanded)
        keyRowGroup.isHidden = false
        // Compact mode uses the same fixed-height row as the keyboard button;
        // terminal output ends above it rather than rendering underneath it.
        controlsHeight.constant = 48
        keyRowHeight.constant = 44
        if expanded {
            NSLayoutConstraint.deactivate([compactKeyRowLeading, compactKeyRowTrailing])
            NSLayoutConstraint.activate([expandedKeyRowLeading, expandedKeyRowTrailing])
        } else {
            NSLayoutConstraint.deactivate([expandedKeyRowLeading, expandedKeyRowTrailing])
            NSLayoutConstraint.activate([compactKeyRowLeading, compactKeyRowTrailing])
        }
        if compact {
            keyRowGroup.effect = nil
        } else if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = true
            keyRowGroup.effect = effect
        } else {
            keyRowGroup.effect = UIBlurEffect(style: .systemMaterial)
        }
        setNeedsUpdateConstraints()
        updateConstraintsIfNeeded()
        setNeedsLayout()
        layoutIfNeeded()
    }
}


struct TerminalThemeStyle: Equatable {
    let foreground: TerminalColorPreference
    let background: TerminalColorPreference
    let ansiPalette: [TerminalColorPreference]
}

@MainActor
enum TerminalSurfaceConfiguration {
    static let bottomControlTopSpacing: CGFloat = 12
    static let bottomControlSafeAreaSpacing: CGFloat = 24
    static let keyboardDismissMode: UIScrollView.KeyboardDismissMode = .none
    static let scrollsToTop = false
    static let contentPadding: CGFloat = 2

    private static let solarizedPalette = palette([
        0x002B36, 0xDC322F, 0x859900, 0xB58900,
        0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
        0x073642, 0xCB4B16, 0x586E75, 0x657B83,
        0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
    ])
    private static let draculaPalette = palette([
        0x282A36, 0xFF5555, 0x50FA7B, 0xF1FA8C,
        0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
        0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5,
        0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
    ])

    static func style(
        for preset: TerminalThemePreset,
        customForeground: TerminalColorPreference,
        customBackground: TerminalColorPreference,
        customPalette: [TerminalColorPreference]
    ) -> TerminalThemeStyle {
        switch preset {
        case .cliveDark:
            return TerminalThemeStyle(
                foreground: .white,
                background: .black,
                ansiPalette: TerminalColorPreference.cliveANSIPalette
            )
        case .dracula:
            return TerminalThemeStyle(
                foreground: color(0xF8F8F2),
                background: color(0x282A36),
                ansiPalette: draculaPalette
            )
        case .solarizedDark:
            return TerminalThemeStyle(
                foreground: color(0x839496),
                background: color(0x002B36),
                ansiPalette: solarizedPalette
            )
        case .solarizedLight:
            return TerminalThemeStyle(
                foreground: color(0x657B83),
                background: color(0xFDF6E3),
                ansiPalette: solarizedPalette
            )
        case .custom:
            return TerminalThemeStyle(
                foreground: customForeground,
                background: customBackground,
                ansiPalette: customPalette.count == 16 ? customPalette : TerminalColorPreference.cliveANSIPalette
            )
        }
    }

    static func apply(_ style: TerminalThemeStyle, to terminal: TerminalView) {
        terminal.nativeForegroundColor = style.foreground.uiColor
        terminal.nativeBackgroundColor = style.background.uiColor
        terminal.backgroundColor = style.background.uiColor
        terminal.installColors(style.ansiPalette.map(\.swiftTermColor))
    }

    private static func palette(_ values: [UInt32]) -> [TerminalColorPreference] {
        values.map { TerminalColorPreference(hex: $0) }
    }

    private static func color(_ value: UInt32) -> TerminalColorPreference {
        TerminalColorPreference(hex: value)
    }
}

@MainActor
extension TerminalColorPreference {
    var uiColor: UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    var swiftTermColor: SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(red) * 257, green: UInt16(green) * 257, blue: UInt16(blue) * 257)
    }

    var swiftUIColor: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    init(color: Color) {
        let uiColor = UIColor(color)
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: nil) else {
            self = .white
            return
        }
        self.init(
            red: UInt8((min(max(red, 0), 1) * 255).rounded()),
            green: UInt8((min(max(green, 0), 1) * 255).rounded()),
            blue: UInt8((min(max(blue, 0), 1) * 255).rounded())
        )
    }
}

@MainActor private final class TerminalLeftEdgeObserver: NSObject, UIGestureRecognizerDelegate {
    private weak var view: TerminalView?
    private let open: () -> Void
    private lazy var gesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handle(_:)))

    static func install(on view: TerminalView, open: @escaping () -> Void) -> TerminalLeftEdgeObserver {
        let observer = TerminalLeftEdgeObserver(view: view, open: open)
        observer.gesture.edges = .left
        observer.gesture.delegate = observer
        view.addGestureRecognizer(observer.gesture)
        return observer
    }
    private init(view: TerminalView, open: @escaping () -> Void) { self.view = view; self.open = open }
    @objc private func handle(_ gesture: UIScreenEdgePanGestureRecognizer) {
        if gesture.state == .began { open() }
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { view != nil }
}

@MainActor private final class TerminalRightEdgeObserver: NSObject, UIGestureRecognizerDelegate {
    private weak var view: TerminalView?
    private let create: () -> Void
    private lazy var gesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handle(_:)))

    static func install(on view: TerminalView, create: @escaping () -> Void) -> TerminalRightEdgeObserver {
        let observer = TerminalRightEdgeObserver(view: view, create: create)
        observer.gesture.edges = .right
        observer.gesture.delegate = observer
        view.addGestureRecognizer(observer.gesture)
        return observer
    }

    private init(view: TerminalView, create: @escaping () -> Void) {
        self.view = view
        self.create = create
    }

    @objc private func handle(_ gesture: UIScreenEdgePanGestureRecognizer) {
        if gesture.state == .began { create() }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { view != nil }
}

@MainActor private final class TerminalHorizontalSwitchObserver: NSObject, UIGestureRecognizerDelegate {
    private weak var view: TerminalView?
    private let selectAdjacent: (Bool) -> Void
    private lazy var gesture = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
    private var handledCurrentGesture = false

    static func install(
        on view: TerminalView,
        selectAdjacent: @escaping (Bool) -> Void
    ) -> TerminalHorizontalSwitchObserver {
        let observer = TerminalHorizontalSwitchObserver(view: view, selectAdjacent: selectAdjacent)
        observer.gesture.minimumNumberOfTouches = 1
        observer.gesture.maximumNumberOfTouches = 1
        observer.gesture.delegate = observer
        view.addGestureRecognizer(observer.gesture)
        return observer
    }

    private init(view: TerminalView, selectAdjacent: @escaping (Bool) -> Void) {
        self.view = view
        self.selectAdjacent = selectAdjacent
    }

    @objc private func handle(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            handledCurrentGesture = false
        case .changed, .ended:
            let translation = gesture.translation(in: view)
            guard !handledCurrentGesture,
                  abs(translation.x) > 20,
                  abs(translation.x) > abs(translation.y) else { return }
            handledCurrentGesture = true
            selectAdjacent(translation.x < 0)
        case .cancelled, .failed:
            handledCurrentGesture = false
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view, gesture.numberOfTouches == 1 else { return false }
        let velocity = gesture.velocity(in: view)
        return abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view else { return false }
        return TerminalHorizontalNavigationPolicy.allowsTerminalSwipe(startingAt: touch.location(in: view).x)
    }
}
