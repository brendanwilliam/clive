import AppIntents
import ActivityKit
import CliveCore
import SwiftUI
import WidgetKit

private let newTerminalAction = "new-terminal"

private struct TerminalActionOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> ItemCollection<String> {
        var items = [IntentItem<String>(newTerminalAction, title: "New terminal")]
        if let group = Bundle.main.object(forInfoDictionaryKey: "CliveAppGroup") as? String,
           let choices = UserDefaults(suiteName: group)?.array(forKey: "widget.shortcuts") as? [[String: String]] {
            let shortcutItems: [IntentItem<String>] = choices.compactMap { choice in
                guard let id = choice["id"], let name = choice["name"] else { return nil }
                return IntentItem(id, title: LocalizedStringResource(stringLiteral: name))
            }
            items += shortcutItems
        }
        return ItemCollection(sections: [ItemSection(items: items)])
    }
}

private struct TerminalWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Terminal action"
    static let description = IntentDescription("Start a new terminal or run a saved shortcut in a new terminal.")

    @Parameter(title: "Action", optionsProvider: TerminalActionOptionsProvider())
    var action: String?
}

private struct TerminalEntry: TimelineEntry {
    let date: Date
    let action: String
    let title: String
}

private struct TerminalProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TerminalEntry {
        TerminalEntry(date: .now, action: newTerminalAction, title: "New terminal")
    }

    func snapshot(for configuration: TerminalWidgetConfiguration, in context: Context) async -> TerminalEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: TerminalWidgetConfiguration, in context: Context) async -> Timeline<TerminalEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: TerminalWidgetConfiguration) -> TerminalEntry {
        let action = configuration.action ?? newTerminalAction
        guard action != newTerminalAction,
              let group = Bundle.main.object(forInfoDictionaryKey: "CliveAppGroup") as? String,
              let choices = UserDefaults(suiteName: group)?.array(forKey: "widget.shortcuts") as? [[String: String]],
              let title = choices.first(where: { $0["id"] == action })?["name"] else {
            return TerminalEntry(date: .now, action: newTerminalAction, title: "New terminal")
        }
        return TerminalEntry(date: .now, action: action, title: title)
    }
}

private struct TerminalWidgetView: View {
    var entry: TerminalEntry
    @Environment(\.widgetFamily) private var family

    private var url: URL {
        entry.action == newTerminalAction
            ? URL(string: "clive://new-terminal")!
            : URL(string: "clive://shortcut/\(entry.action)")!
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: entry.action == newTerminalAction ? "plus.rectangle.on.rectangle" : "terminal.fill")
                .font(family == .systemMedium ? .largeTitle : .title)
            VStack(alignment: .leading, spacing: 4) {
                if family == .systemSmall { Spacer() }
                Text(entry.title).font(.headline).lineLimit(2)
                Text(entry.action == newTerminalAction ? "Terminal" : "Shortcut")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: family == .systemMedium ? .center : .topLeading)
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(url)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.action == newTerminalAction ? "New terminal in Clive" : "Run \(entry.title) in a new terminal in Clive")
    }
}

struct CliveResumeWidget: Widget {
    let kind = "CliveResumeWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TerminalWidgetConfiguration.self, provider: TerminalProvider()) { entry in
            TerminalWidgetView(entry: entry)
        }
        .configurationDisplayName("Terminal")
        .description("Start a new terminal or run one of your saved shortcuts.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@available(iOS 17.0, *)
private struct CliveTerminalLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CliveTerminalActivityAttributes.self) { context in
            LiveActivitySummary(state: context.state)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(liveActivityURL(for: context.state))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "terminal.fill") }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.requiresAttention { Image(systemName: "exclamationmark.circle.fill") }
                }
                DynamicIslandExpandedRegion(.bottom) { LiveActivitySummary(state: context.state) }
            } compactLeading: {
                Image(systemName: "terminal.fill")
            } compactTrailing: {
                Text("\(context.state.activeTerminalCount)")
            } minimal: {
                Image(systemName: context.state.requiresAttention ? "exclamationmark.circle.fill" : "terminal.fill")
            }
            .widgetURL(liveActivityURL(for: context.state))
        }
    }

    private func liveActivityURL(for state: CliveTerminalActivityAttributes.ContentState) -> URL {
        if let id = state.attentionTerminalID { return URL(string: "clive://terminal/\(id.uuidString)")! }
        return URL(string: "clive://terminals")!
    }
}

@available(iOS 17.0, *)
private struct LiveActivitySummary: View {
    let state: CliveTerminalActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(state.activeTerminalCount) terminal\(state.activeTerminalCount == 1 ? "" : "s") active")
                .font(.headline)
            if state.requiresAttention {
                Label("Action required", systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.requiresAttention
            ? "\(state.activeTerminalCount) terminals active. Action required."
            : "\(state.activeTerminalCount) terminals active.")
    }
}

@main
struct CliveWidgets: WidgetBundle {
    var body: some Widget {
        CliveResumeWidget()
        if #available(iOS 17.0, *) { CliveTerminalLiveActivity() }
    }
}
