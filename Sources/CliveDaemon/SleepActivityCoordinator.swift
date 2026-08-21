import Foundation
import IOKit.pwr_mgt

protocol SleepAssertionProviding: Sendable {
    func acquire() -> IOPMAssertionID?
    func release(_ id: IOPMAssertionID)
}

struct SystemSleepAssertionProvider: SleepAssertionProviding {
    func acquire() -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Active Clive terminal" as CFString,
            &id
        )
        return result == kIOReturnSuccess ? id : nil
    }
    func release(_ id: IOPMAssertionID) { IOPMAssertionRelease(id) }
}

/// Holds one daemon-wide assertion, without inspecting terminal bytes.
final class SleepActivityCoordinator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.clive.daemon.sleep-activity")
    private let provider: SleepAssertionProviding
    private let interval: TimeInterval
    private var activity: [UUID: Date] = [:]
    private var assertion: IOPMAssertionID?
    private var timer: DispatchWorkItem?

    init(provider: SleepAssertionProviding = SystemSleepAssertionProvider(), interval: TimeInterval = 30 * 60) {
        self.provider = provider; self.interval = interval
    }
    func noteActivity(sessionID: UUID) { queue.async { self.activity[sessionID] = Date(); self.refresh() } }
    func end(sessionID: UUID) { queue.async { self.activity.removeValue(forKey: sessionID); self.refresh() } }
    func shutdown() { queue.sync { activity.removeAll(); refresh() } }

    private func refresh() {
        let cutoff = Date().addingTimeInterval(-interval)
        activity = activity.filter { $0.value > cutoff }
        timer?.cancel(); timer = nil
        if activity.isEmpty {
            if let assertion { provider.release(assertion); self.assertion = nil }
            return
        }
        if assertion == nil { assertion = provider.acquire() }
        guard let next = activity.values.min() else { return }
        let work = DispatchWorkItem { [weak self] in self?.refresh() }; timer = work
        queue.asyncAfter(deadline: .now() + max(0.01, next.addingTimeInterval(interval).timeIntervalSinceNow), execute: work)
    }
}
