import AppIntents
import Foundation

enum ExternalLaunchURL {
    static let resumeOrStart = URL(string: "clive://resume-or-start")!

    static func matches(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "clive"
            && components.host == "resume-or-start"
            && (components.path.isEmpty || components.path == "/")
            && components.query == nil
            && components.fragment == nil
    }
}

extension Notification.Name {
    static let externalTerminalLaunchRequested = Notification.Name("com.clive.external-launch-requested")
}

struct ExternalLaunchRequestStore {
    private static let requestedKey = "externalLaunch.requestedGeneration"
    private static let handledKey = "externalLaunch.handledGeneration"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func request() {
        let next = defaults.integer(forKey: Self.requestedKey) + 1
        defaults.set(next, forKey: Self.requestedKey)
        NotificationCenter.default.post(name: .externalTerminalLaunchRequested, object: nil)
    }

    @discardableResult func consumePending() -> Bool {
        let requested = defaults.integer(forKey: Self.requestedKey)
        guard requested > defaults.integer(forKey: Self.handledKey) else { return false }
        defaults.set(requested, forKey: Self.handledKey)
        return true
    }
}

struct ResumeOrStartTerminalIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume or Start Terminal"
    static let description = IntentDescription("Opens Clive to the last terminal screen, or starts a new terminal when none can be restored.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        ExternalLaunchRequestStore().request()
        return .result()
    }
}

struct CliveAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumeOrStartTerminalIntent(),
            phrases: [
                "Resume my terminal in \(.applicationName)",
                "Start a terminal in \(.applicationName)",
                "Open \(.applicationName)"
            ],
            shortTitle: "Resume Terminal",
            systemImageName: "terminal"
        )
    }
}
