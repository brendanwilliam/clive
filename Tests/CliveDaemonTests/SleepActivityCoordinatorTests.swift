import Foundation
import IOKit.pwr_mgt
import XCTest
@testable import CliveDaemon

private final class FakeClock: MonotonicClock, @unchecked Sendable { var now: TimeInterval = 0 }
private final class FakeAssertionProvider: SleepAssertionProviding, @unchecked Sendable {
    var acquisitions = 0
    var releases: [IOPMAssertionID] = []
    func acquire() -> IOPMAssertionID? { acquisitions += 1; return IOPMAssertionID(acquisitions) }
    func release(_ id: IOPMAssertionID) { releases.append(id) }
}
private final class FakeAction: ScheduledAction, @unchecked Sendable {
    var cancelled = false; let block: @Sendable () -> Void
    init(_ block: @escaping @Sendable () -> Void) { self.block = block }
    func cancel() { cancelled = true }
}
private final class FakeScheduler: ActionScheduling, @unchecked Sendable {
    var actions: [FakeAction] = []
    func schedule(after delay: TimeInterval, _ action: @escaping @Sendable () -> Void) -> any ScheduledAction {
        let item = FakeAction(action); actions.append(item); return item
    }
    func fireLatest() { guard let action = actions.last, !action.cancelled else { return }; action.block() }
}

final class SleepActivityCoordinatorTests: XCTestCase {
    func testActivityAcquiresRefreshesAndExpiresOneSharedAssertion() {
        let clock = FakeClock(), provider = FakeAssertionProvider(), scheduler = FakeScheduler()
        let coordinator = SleepActivityCoordinator(provider: provider, interval: 30, clock: clock, scheduler: scheduler)
        let first = UUID(), second = UUID()

        coordinator.noteActivity(sessionID: first); coordinator.synchronize()
        clock.now = 10; coordinator.noteActivity(sessionID: second); coordinator.synchronize()
        XCTAssertEqual(provider.acquisitions, 1)

        clock.now = 31; scheduler.fireLatest(); coordinator.synchronize()
        XCTAssertTrue(provider.releases.isEmpty)
        clock.now = 41; scheduler.fireLatest(); coordinator.synchronize()
        XCTAssertEqual(provider.releases.count, 1)
    }

    func testEndAndShutdownReleaseAssertion() {
        let clock = FakeClock(), provider = FakeAssertionProvider(), scheduler = FakeScheduler()
        let coordinator = SleepActivityCoordinator(provider: provider, clock: clock, scheduler: scheduler)
        let session = UUID()
        coordinator.noteActivity(sessionID: session); coordinator.synchronize()
        coordinator.end(sessionID: session); coordinator.synchronize()
        XCTAssertEqual(provider.releases.count, 1)

        coordinator.noteActivity(sessionID: UUID()); coordinator.synchronize(); coordinator.shutdown()
        XCTAssertEqual(provider.releases.count, 2)
    }
}
