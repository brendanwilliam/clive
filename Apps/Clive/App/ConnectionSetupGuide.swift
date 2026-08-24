import Foundation

/// UI-only configuration for helping a person install and pair Clive.
/// This URL is public discovery information; it is never a pairing payload.
enum ConnectionSetupGuideConfiguration {
    static let testFlightURL = URL(string: "https://testflight.apple.com/join/SUcN1FkH")!
    static let macInstallCommand = "brew install --cask brendanwilliam/tap/clive"
}

/// Keeps automatic setup presentation scoped to one app launch.
struct ConnectionSetupPresentationPolicy: Equatable {
    private(set) var didAutoPresent = false

    mutating func shouldAutoPresent(hasPairedDevice: Bool) -> Bool {
        guard !hasPairedDevice, !didAutoPresent else { return false }
        didAutoPresent = true
        return true
    }

    mutating func completePairing() {
        didAutoPresent = true
    }
}
