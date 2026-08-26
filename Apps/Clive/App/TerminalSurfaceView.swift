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
    let openDrawer: () -> Void
    let selectAdjacentTerminal: (Bool) -> Void
    let runShortcut: (CLIShortcut) -> Bool
    let manageShortcuts: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            session: session,
            shortcuts: shortcuts,
            openDrawer: openDrawer,
            selectAdjacentTerminal: selectAdjacentTerminal,
            runShortcut: runShortcut,
            manageShortcuts: manageShortcuts
        )
    }

    func makeUIView(context: Context) -> TerminalSurfaceContainer {
        let container = TerminalSurfaceContainer()
        let terminal = container.terminal
        terminal.terminalDelegate = context.coordinator
        // SwiftTerm installs its own TerminalAccessory by default. Clive owns the
        // terminal key toolbar, so do not stack SwiftTerm's accessory above it.
        terminal.inputAccessoryView = nil
        terminal.linkReporting = .implicit
        terminal.linkHighlightMode = .hoverWithModifier
        terminal.installColors(TerminalSurfaceConfiguration.ansiColors)
        terminal.accessibilityIdentifier = accessibilityIdentifier
        terminal.accessibilityLabel = "Terminal"
        terminal.accessibilityValue = isSelected ? "Selected" : "Not selected"
        terminal.keyboardDismissMode = TerminalSurfaceConfiguration.keyboardDismissMode
        terminal.scrollsToTop = TerminalSurfaceConfiguration.scrollsToTop
        context.coordinator.install(on: container)
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let fixtureOutput = (1...80).map { $0 == 80 ? "https://example.com" : "fixture line \($0)" }.joined(separator: "\r\n")
            terminal.feed(byteArray: ArraySlice(("\u{1b}[2 q" + fixtureOutput).utf8))
        }
        session?.onOutput = { [weak terminal] data in DispatchQueue.main.async { terminal?.feed(byteArray: ArraySlice(data)) } }
        return container
    }

    func updateUIView(_ uiView: TerminalSurfaceContainer, context: Context) {
        context.coordinator.session = session
        context.coordinator.shortcuts = shortcuts
        context.coordinator.openDrawer = openDrawer
        context.coordinator.selectAdjacentTerminal = selectAdjacentTerminal
        context.coordinator.runShortcut = runShortcut
        context.coordinator.manageShortcuts = manageShortcuts
        uiView.configureShortcutMenu(
            shortcuts,
            run: runShortcut,
            manage: manageShortcuts
        )
        uiView.terminal.accessibilityIdentifier = accessibilityIdentifier
        uiView.terminal.accessibilityValue = isSelected ? "Selected" : "Not selected"
    }

    final class Coordinator: NSObject, TerminalViewDelegate, @unchecked Sendable {
        var session: SessionClient?
        var shortcuts: [CLIShortcut]
        var openDrawer: () -> Void
        var selectAdjacentTerminal: (Bool) -> Void
        var runShortcut: (CLIShortcut) -> Bool
        var manageShortcuts: () -> Void
        private weak var container: TerminalSurfaceContainer?
        private var accessory: TerminalKeyboardAccessory?
        private var edgeObserver: TerminalLeftEdgeObserver?
        private var horizontalSwitchObserver: TerminalHorizontalSwitchObserver?

        init(
            session: SessionClient?,
            shortcuts: [CLIShortcut],
            openDrawer: @escaping () -> Void,
            selectAdjacentTerminal: @escaping (Bool) -> Void,
            runShortcut: @escaping (CLIShortcut) -> Bool,
            manageShortcuts: @escaping () -> Void
        ) {
            self.session = session
            self.shortcuts = shortcuts
            self.openDrawer = openDrawer
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
            horizontalSwitchObserver = TerminalHorizontalSwitchObserver.install(on: container.terminal) { [weak self] forward in
                self?.selectAdjacentTerminal(forward)
            }
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        addSubview(controls)
        let focusGesture = UITapGestureRecognizer(target: self, action: #selector(focusTerminal))
        focusGesture.cancelsTouchesInView = false
        terminal.addGestureRecognizer(focusGesture)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor), terminal.leadingAnchor.constraint(equalTo: leadingAnchor), terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: controls.topAnchor),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor), controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor), controls.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
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
        controls.setKeyboardVisible(keyboardVisible)
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
    private var compactKeyRowWidth: NSLayoutConstraint!
    private var expandedKeyRowLeading: NSLayoutConstraint!
    private var expandedKeyRowTrailing: NSLayoutConstraint!
    private var controlsHeight: NSLayoutConstraint!
    private var keyRowHeight: NSLayoutConstraint!
    private var keyRow: TerminalKeyboardAccessory?
    private var keyboardVisible = false
    private var policy = TerminalInputControlPolicy()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        [keyboardGroup, keyRowGroup, shortcutsGroup].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.layer.cornerRadius = 22
            $0.layer.cornerCurve = .continuous
            $0.clipsToBounds = true
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
        compactKeyRowTrailing = keyRowGroup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        compactKeyRowWidth = keyRowGroup.widthAnchor.constraint(equalToConstant: 44)
        expandedKeyRowLeading = keyRowGroup.leadingAnchor.constraint(equalTo: shortcutsGroup.trailingAnchor, constant: 4)
        expandedKeyRowTrailing = keyRowGroup.trailingAnchor.constraint(equalTo: keyboardGroup.leadingAnchor, constant: -4)
        controlsHeight = heightAnchor.constraint(equalToConstant: 144)
        keyRowHeight = keyRowGroup.heightAnchor.constraint(equalToConstant: 140)
        NSLayoutConstraint.activate([
            keyRowGroup.centerYAnchor.constraint(equalTo: centerYAnchor), keyRowHeight,
            compactKeyRowTrailing,
            compactKeyRowWidth,
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
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: rowHost.leadingAnchor), row.trailingAnchor.constraint(equalTo: rowHost.trailingAnchor), row.topAnchor.constraint(equalTo: rowHost.topAnchor), row.bottomAnchor.constraint(equalTo: rowHost.bottomAnchor)])
    }
    func setKeyboardVisible(_ visible: Bool) { keyboardVisible = visible; policy.keyboardChanged(visible: visible); updateAppearance() }
    func configureShortcutMenu(
        shortcuts: [CLIShortcut],
        run: @escaping (CLIShortcut) -> Bool,
        manage: @escaping () -> Void
    ) {
        let shortcutActions = shortcuts.map { shortcut in
            let command = shortcut.command.trimmingCharacters(in: .whitespacesAndNewlines)
            return UIAction(
                title: shortcut.name.isEmpty ? "Unnamed shortcut" : shortcut.name,
                image: UIImage(systemName: Self.shortcutSymbolName),
                attributes: command.isEmpty ? .disabled : []
            ) { _ in
                _ = run(shortcut)
            }
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
        keyboardButton.isHidden = !expanded
        keyboardGroup.isHidden = !expanded
        keyRow?.setKeyboardVisible(expanded)
        keyRowGroup.isHidden = false
        controlsHeight.constant = compact ? 144 : 48
        keyRowHeight.constant = compact ? 140 : 44
        if expanded {
            NSLayoutConstraint.deactivate([compactKeyRowTrailing, compactKeyRowWidth])
            NSLayoutConstraint.activate([expandedKeyRowLeading, expandedKeyRowTrailing])
        } else {
            NSLayoutConstraint.deactivate([expandedKeyRowLeading, expandedKeyRowTrailing])
            NSLayoutConstraint.activate([compactKeyRowTrailing, compactKeyRowWidth])
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


@MainActor
enum TerminalSurfaceConfiguration {
    static let keyboardDismissMode: UIScrollView.KeyboardDismissMode = .none
    static let scrollsToTop = false
    static let contentPadding: CGFloat = 2
    static let ansiColors: [SwiftTerm.Color] = [
        color(0x00, 0x00, 0x00), color(0xC2, 0x36, 0x21),
        color(0x25, 0xBC, 0x24), color(0xAD, 0xAD, 0x27),
        color(0x49, 0x2E, 0xE1), color(0xD3, 0x38, 0xD3),
        color(0x33, 0xBB, 0xC8), color(0xCB, 0xCC, 0xCD),
        color(0x81, 0x83, 0x83), color(0xFC, 0x39, 0x1F),
        color(0x31, 0xE7, 0x22), color(0xEA, 0xEC, 0x23),
        color(0x58, 0x33, 0xFF), color(0xF9, 0x35, 0xF8),
        color(0x14, 0xF0, 0xF0), color(0xE9, 0xEB, 0xEB),
    ]

    private static func color(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: red * 257, green: green * 257, blue: blue * 257)
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
