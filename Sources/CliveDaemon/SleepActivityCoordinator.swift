import Foundation
import IOKit.pwr_mgt

protocol SleepAssertionProviding: Sendable {
    func acquire() -> IOPMAssertionID?
    func release(_ id: IOPMAssertionID)
}

protocol MonotonicClock: Sendable { var now: TimeInterval { get } }

struct SystemMonotonicClock: MonotonicClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

protocol ScheduledAction: Sendable { func cancel() }
protocol ActionScheduling: Sendable {
    func schedule(after delay: TimeInterval, _ action: @escaping @Sendable () -> Void) -> any ScheduledAction
}

private final class DispatchScheduledAction: ScheduledAction, @unchecked Sendable {
    let work: DispatchWorkItem
    init(_ work: DispatchWorkItem) { self.work = work }
    func cancel() { work.cancel() }
}

struct DispatchActionScheduler: ActionScheduling {
    let queue: DispatchQueue
    func schedule(after delay: TimeInterval, _ action: @escaping @Sendable () -> Void) -> any ScheduledAction {
        let work = DispatchWorkItem(block: action)
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: work)
        return DispatchScheduledAction(work)
    }
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
    private let clock: any MonotonicClock
    private let scheduler: any ActionScheduling
    private var activity: [UUID: TimeInterval] = [:]
    private var assertion: IOPMAssertionID?
    private var timer: (any ScheduledAction)?

    init(provider: SleepAssertionProviding = SystemSleepAssertionProvider(), interval: TimeInterval = 30 * 60, clock: any MonotonicClock = SystemMonotonicClock(), scheduler: (any ActionScheduling)? = nil) {
        self.provider = provider; self.interval = interval; self.clock = clock
        self.scheduler = scheduler ?? DispatchActionScheduler(queue: queue)
    }
    func noteActivity(sessionID: UUID) { queue.async { self.activity[sessionID] = self.clock.now; self.refresh() } }
    func end(sessionID: UUID) { queue.async { self.activity.removeValue(forKey: sessionID); self.refresh() } }
    func shutdown() { queue.sync { activity.removeAll(); refresh() } }
    func synchronize() { queue.sync {} }

    private func refresh() {
        let now = clock.now
        let cutoff = now - interval
        activity = activity.filter { $0.value > cutoff }
        timer?.cancel(); timer = nil
        if activity.isEmpty {
            if let assertion { provider.release(assertion); self.assertion = nil }
            return
        }
        if assertion == nil { assertion = provider.acquire() }
        guard let next = activity.values.min() else { return }
        timer = scheduler.schedule(after: max(0.01, next + interval - now)) { [weak self] in
            guard let self else { return }
            self.queue.async { self.refresh() }
        }
    }
}
