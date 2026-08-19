import SwiftUI
import WidgetKit

private struct ResumeEntry: TimelineEntry {
    let date: Date
}

private struct ResumeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ResumeEntry { ResumeEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (ResumeEntry) -> Void) { completion(ResumeEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ResumeEntry>) -> Void) {
        completion(Timeline(entries: [ResumeEntry(date: .now)], policy: .never))
    }
}

private struct ResumeWidgetView: View {
    var entry: ResumeEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let labels = VStack(alignment: .leading, spacing: 4) {
            if family == .systemSmall { Spacer() }
            Text("Resume or Start")
                .font(.headline)
            Text("Terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: family == .systemMedium ? .center : .topLeading)

        Group {
            if family == .systemMedium {
                HStack(spacing: 16) {
                    Image(systemName: "terminal.fill").font(.largeTitle)
                    labels
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "terminal.fill").font(.title)
                    labels
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "clive://resume-or-start"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Resume or start terminal in Clive")
    }
}

@main
struct CliveResumeWidget: Widget {
    let kind = "CliveResumeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ResumeProvider()) { entry in
            ResumeWidgetView(entry: entry)
        }
        .configurationDisplayName("Resume Terminal")
        .description("Open the last terminal screen or start a new terminal.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
