import Foundation

package enum CompanionStartupPolicy {
    package static func run<Value>(
        companionIsInstalled: Bool,
        timeout: TimeInterval = 5,
        retryInterval: TimeInterval = 0.1,
        now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = Thread.sleep,
        launch: () throws -> Void,
        request: () throws -> Value,
        isUnavailable: (Error) -> Bool
    ) throws -> Value {
        do {
            return try request()
        } catch {
            guard companionIsInstalled, isUnavailable(error) else { throw error }
        }

        try launch()
        let deadline = now().addingTimeInterval(timeout)
        while true {
            do {
                return try request()
            } catch {
                guard isUnavailable(error), now() < deadline else { throw error }
                sleep(retryInterval)
            }
        }
    }
}
