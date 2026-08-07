import LocalAuthentication

enum LocalAuthenticator {
    static func authorizeConnection() async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw error ?? AuthenticationError.unavailable
        }
        try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock terminal access to your paired Mac.")
    }

    enum AuthenticationError: Error {
        case unavailable
    }
}
