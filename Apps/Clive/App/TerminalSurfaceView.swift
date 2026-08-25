import CliveCore
import SwiftTerm
import SwiftUI

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
        private var twoFingerObserver: TerminalTwoFingerSwitchObserver?

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
            container.onShortcutsRequested = { [weak self] in
                guard let self, let container = self.container else { return }
                container.presentShortcuts(
                    self.shortcuts,
                    run: self.runShortcut,
                    manage: self.manageShortcuts
                )
            }
            edgeObserver = TerminalLeftEdgeObserver.install(on: container.terminal) { [weak self] in self?.openDrawer() }
            twoFingerObserver = TerminalTwoFingerSwitchObserver.install(on: container.terminal) { [weak self] forward in
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
    var onShortcutsRequested: (() -> Void)?
    private let controls = TerminalBottomControls()
    private weak var shortcutPanel: UIViewController?

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
        controls.onShortcuts = { [weak self] in self?.onShortcutsRequested?() }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func focusTerminal() {
        _ = terminal.becomeFirstResponder()
    }

    func installKeyRow(_ row: TerminalKeyboardAccessory) { controls.installKeyRow(row) }

    func presentShortcuts(
        _ shortcuts: [CLIShortcut],
        run: @escaping (CLIShortcut) -> Bool,
        manage: @escaping () -> Void
    ) {
        guard shortcutPanel == nil,
              let viewController = window?.rootViewController?.topMostViewController else { return }
        controls.beginShortcuts()
        let panel = ShortcutPanelViewController(
            shortcuts: shortcuts,
            run: run,
            manage: manage,
            dismissed: { [weak self] in
                self?.controls.endShortcuts()
                self?.shortcutPanel = nil
            }
        )
        panel.modalPresentationStyle = .popover
        panel.popoverPresentationController?.sourceView = controls.shortcutButton
        panel.popoverPresentationController?.sourceRect = controls.shortcutButton.bounds
        panel.popoverPresentationController?.permittedArrowDirections = .down
        panel.popoverPresentationController?.delegate = panel
        panel.preferredContentSize = CGSize(width: 320, height: 320)
        shortcutPanel = panel
        viewController.present(panel, animated: true)
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let window else { return }
        let keyboardVisible = window.convert(frame, from: nil).intersects(window.bounds) && frame.minY < window.bounds.height
        controls.setKeyboardVisible(keyboardVisible)
    }
}

@MainActor final class TerminalBottomControls: UIView {
    var onKeyboard: ((Bool) -> Void)?
    var onShortcuts: (() -> Void)?
    private let keyboardButton = UIButton(type: .system)
    let shortcutButton = UIButton(type: .system)
    private let keyboardGroup = UIVisualEffectView(effect: nil)
    private let keyRowGroup = UIVisualEffectView(effect: nil)
    private let shortcutsGroup = UIVisualEffectView(effect: nil)
    private let rowHost = UIView()
    private var keyRow: TerminalKeyboardAccessory?
    private var keyboardVisible = false
    private var policy = TerminalInputControlPolicy()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        [keyboardGroup, keyRowGroup, shortcutsGroup].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.layer.cornerRadius = 14
            $0.layer.cornerCurve = .continuous
            $0.clipsToBounds = true
            addSubview($0)
        }
        keyboardButton.accessibilityIdentifier = "terminal-keyboard-button"
        shortcutButton.accessibilityIdentifier = "terminal-shortcuts-button"
        shortcutButton.accessibilityLabel = "Shortcuts"
        keyboardButton.addTarget(self, action: #selector(toggleKeyboard), for: .touchUpInside)
        shortcutButton.addTarget(self, action: #selector(showShortcuts), for: .touchUpInside)
        keyboardButton.translatesAutoresizingMaskIntoConstraints = false
        shortcutButton.translatesAutoresizingMaskIntoConstraints = false
        rowHost.translatesAutoresizingMaskIntoConstraints = false
        keyboardGroup.contentView.addSubview(keyboardButton)
        keyRowGroup.contentView.addSubview(rowHost)
        shortcutsGroup.contentView.addSubview(shortcutButton)
        NSLayoutConstraint.activate([
            shortcutsGroup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), shortcutsGroup.widthAnchor.constraint(equalToConstant: 44), shortcutsGroup.heightAnchor.constraint(equalToConstant: 44), shortcutsGroup.centerYAnchor.constraint(equalTo: centerYAnchor),
            keyboardGroup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), keyboardGroup.widthAnchor.constraint(equalToConstant: 44), keyboardGroup.heightAnchor.constraint(equalToConstant: 44), keyboardGroup.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 48),
            keyboardButton.leadingAnchor.constraint(equalTo: keyboardGroup.contentView.leadingAnchor), keyboardButton.trailingAnchor.constraint(equalTo: keyboardGroup.contentView.trailingAnchor), keyboardButton.topAnchor.constraint(equalTo: keyboardGroup.contentView.topAnchor), keyboardButton.bottomAnchor.constraint(equalTo: keyboardGroup.contentView.bottomAnchor),
            shortcutButton.leadingAnchor.constraint(equalTo: shortcutsGroup.contentView.leadingAnchor), shortcutButton.trailingAnchor.constraint(equalTo: shortcutsGroup.contentView.trailingAnchor), shortcutButton.topAnchor.constraint(equalTo: shortcutsGroup.contentView.topAnchor), shortcutButton.bottomAnchor.constraint(equalTo: shortcutsGroup.contentView.bottomAnchor),
            rowHost.leadingAnchor.constraint(equalTo: keyRowGroup.contentView.leadingAnchor), rowHost.trailingAnchor.constraint(equalTo: keyRowGroup.contentView.trailingAnchor), rowHost.topAnchor.constraint(equalTo: keyRowGroup.contentView.topAnchor), rowHost.bottomAnchor.constraint(equalTo: keyRowGroup.contentView.bottomAnchor),
        ])
        NSLayoutConstraint.activate([
            keyRowGroup.centerYAnchor.constraint(equalTo: centerYAnchor),
            keyRowGroup.heightAnchor.constraint(equalToConstant: 40),
        ])
        shortcutButton.setImage(UIImage(systemName: "bolt.fill"), for: .normal)
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
    func beginShortcuts() {
        policy.openShortcuts()
        if keyboardVisible { onKeyboard?(true) }
        updateAppearance()
    }
    func endShortcuts() {
        policy.dismissShortcuts()
        if policy.state == .keyboard { onKeyboard?(false) }
        updateAppearance()
    }

    @objc private func toggleKeyboard() { onKeyboard?(keyboardVisible) }
    @objc private func showShortcuts() { onShortcuts?() }

    var keyboardControlFrame: CGRect { keyboardGroup.frame }
    var keyRowControlFrame: CGRect { keyRowGroup.frame }
    var shortcutsControlFrame: CGRect { shortcutsGroup.frame }
    var isKeyboardControlVisible: Bool { !keyboardGroup.isHidden }
    var isKeyRowControlVisible: Bool { !keyRowGroup.isHidden }
    var isShortcutsControlVisible: Bool { !shortcutsGroup.isHidden }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutKeyRow()
    }

    private func layoutKeyRow() {
        let keyRowLeading = policy.state == .keyboard ? shortcutsGroup.frame.maxX + 4 : 0
        let keyRowTrailing = policy.state == .keyboard ? keyboardGroup.frame.minX - 4 : bounds.width - 8
        let keyRowWidth = max(0, keyRowTrailing - keyRowLeading)
        keyRowGroup.frame = CGRect(
            x: policy.state == .keyboard ? keyRowLeading : keyRowTrailing - min(136, keyRowWidth),
            y: keyRowGroup.frame.minY,
            width: min(136, keyRowWidth),
            height: keyRowGroup.frame.height
        )
    }

    private func updateAppearance() {
        keyboardButton.setImage(UIImage(systemName: keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard"), for: .normal)
        keyboardButton.accessibilityLabel = keyboardVisible ? "Hide keyboard" : "Show keyboard"
        let expanded = policy.state == .keyboard
        keyboardButton.isHidden = !expanded
        keyboardGroup.isHidden = !expanded
        keyRow?.setKeyboardVisible(expanded)
        keyRowGroup.isHidden = policy.state == .shortcuts
        layoutIfNeeded()
        layoutKeyRow()
    }
}

@MainActor private final class ShortcutPanelViewController: UIViewController, UIPopoverPresentationControllerDelegate {
    private let shortcuts: [CLIShortcut]
    private let run: (CLIShortcut) -> Bool
    private let manage: () -> Void
    private var dismissed: (() -> Void)?

    init(
        shortcuts: [CLIShortcut],
        run: @escaping (CLIShortcut) -> Bool,
        manage: @escaping () -> Void,
        dismissed: @escaping () -> Void
    ) {
        self.shortcuts = shortcuts
        self.run = run
        self.manage = manage
        self.dismissed = dismissed
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        presentationController?.delegate = self
        let content = ShortcutPanelContent(
            shortcuts: shortcuts,
            run: { [weak self] shortcut in
                guard let self, self.run(shortcut) else { return }
                self.dismiss(animated: true)
            },
            manage: { [weak self] in
                guard let self else { return }
                self.dismiss(animated: true) {
                    DispatchQueue.main.async { self.manage() }
                }
            },
        )
        let host = UIHostingController(rootView: content)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finishDismissal() }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        super.dismiss(animated: flag) { [weak self] in
            self?.finishDismissal()
            completion?()
        }
    }

    private func finishDismissal() {
        dismissed?()
        dismissed = nil
    }
}

private struct ShortcutPanelContent: View {
    let shortcuts: [CLIShortcut]
    let run: (CLIShortcut) -> Void
    let manage: () -> Void

    var body: some View {
        List {
            if shortcuts.isEmpty {
                ContentUnavailableView("No shortcuts", systemImage: "bolt", description: Text("Add commands in Settings to run them here."))
            } else {
                ForEach(Array(shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                    Button { run(shortcut) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shortcut.name.isEmpty ? "Unnamed shortcut" : shortcut.name)
                                .foregroundStyle(.primary)
                            Text(shortcut.command)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .disabled(shortcut.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("shortcut-row-\(shortcut.id.uuidString)")
                    .listRowSeparator(.hidden)
                    if index < shortcuts.count - 1 { Divider().listRowInsets(EdgeInsets()) }
                }
            }
            Section {
                Button("Settings", systemImage: "gearshape", action: manage)
                    .accessibilityIdentifier("manage-shortcuts-button")
            }
        }
        .accessibilityIdentifier("shortcuts-panel")
    }
}

private extension UIViewController {
    var topMostViewController: UIViewController {
        if let presentedViewController { return presentedViewController.topMostViewController }
        if let navigationController = self as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return visibleViewController.topMostViewController
        }
        return self
    }
}

enum TerminalSurfaceConfiguration {
    static let keyboardDismissMode: UIScrollView.KeyboardDismissMode = .none
    static let scrollsToTop = false
    static let contentPadding: CGFloat = 2
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

@MainActor private final class TerminalTwoFingerSwitchObserver: NSObject, UIGestureRecognizerDelegate {
    private weak var view: TerminalView?
    private let selectAdjacent: (Bool) -> Void
    private lazy var gesture = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
    private var handledCurrentGesture = false

    static func install(
        on view: TerminalView,
        selectAdjacent: @escaping (Bool) -> Void
    ) -> TerminalTwoFingerSwitchObserver {
        let observer = TerminalTwoFingerSwitchObserver(view: view, selectAdjacent: selectAdjacent)
        observer.gesture.minimumNumberOfTouches = 2
        observer.gesture.maximumNumberOfTouches = 2
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
        guard let view, gesture.numberOfTouches == 2 else { return false }
        let velocity = gesture.velocity(in: view)
        return abs(velocity.x) > abs(velocity.y)
    }
}
