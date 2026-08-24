import ActivityKit
import CliveCore
import Foundation

@available(iOS 17.0, *)
final class LiveActivityController: @unchecked Sendable {
    private var activity: Activity<CliveTerminalActivityAttributes>?

    func reconcile(catalog: [CliveCore.SessionDescriptor]) {
        let active = catalog.count
        let attentionID = catalog.first(where: \.requiresAttention)?.id
        let state = CliveTerminalActivityAttributes.ContentState(
            activeTerminalCount: active,
            requiresAttention: attentionID != nil,
            attentionTerminalID: attentionID
        )
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            if let activity { Task.detached { await activity.end(nil, dismissalPolicy: .immediate) }; self.activity = nil }
            return
        }
        guard active > 0 else {
            if let activity { Task.detached { await activity.end(ActivityContent(state: state, staleDate: .now), dismissalPolicy: .immediate) }; self.activity = nil }
            return
        }
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(5 * 60))
        if let activity {
            Task.detached { await activity.update(content) }
        } else {
            activity = try? Activity.request(attributes: CliveTerminalActivityAttributes(), content: content, pushType: .token)
        }
    }

    func end() {
        guard let activity else { return }
        Task.detached { await activity.end(nil, dismissalPolicy: .immediate) }
        self.activity = nil
    }
}
