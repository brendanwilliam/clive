import Foundation
import CliveCloud
import CliveCore
import CliveSecurity

actor IPhoneRendezvousService {
    struct RouteResult: Sendable { let routes: [MacRoute]; let diagnostic: String? }
    private let cloud: CloudRendezvousStore
    private let keys: RendezvousKeyPair
    private var accountBinding: String?
    private var lastSequence: [String: UInt64] = [:]

    init() throws {
        #if targetEnvironment(simulator)
        throw CloudRendezvousError.entitlementUnavailable
        #else
        let identifier = Bundle.main.object(forInfoDictionaryKey: "CliveCloudContainer") as? String ?? "iCloud.com.clive"
        cloud = CloudRendezvousStore(containerIdentifier: identifier)
        keys = try RendezvousKeyStore(service: "com.clive.iphone.rendezvous").loadOrCreate()
        #endif
    }

    func prepare() async throws -> RendezvousCapability {
        if accountBinding == nil { accountBinding = try await cloud.prepare() }
        return RendezvousCapability(keys: try keys.publicKeys, accountBinding: accountBinding!)
    }

    func routes(for mac: PairedMac, deviceID: String) async -> RouteResult {
        do {
            let local = try await prepare()
            guard let peer = mac.rendezvousCapability else { return RouteResult(routes: [], diagnostic: "Connect to this Mac locally once to upgrade cellular access.") }
            guard peer.accountBinding == local.accountBinding else { return RouteResult(routes: [], diagnostic: "This Mac is signed in to a different Apple Account.") }
            let name = RendezvousCrypto.recordName(macID: mac.id, deviceID: deviceID, purpose: "endpoint")
            guard let envelope = try await cloud.fetch(recordName: name) else {
                try? await sendReachabilityHint(mac: mac, deviceID: deviceID, peer: peer)
                return RouteResult(routes: [], diagnostic: "Asked the Mac to refresh its cellular endpoint. Try again shortly.")
            }
            let advertisement = try RendezvousCrypto.open(envelope, as: RendezvousAdvertisement.self, recipientID: deviceID, recipientAgreementKey: keys.agreementPrivateKey, senderSigningKey: peer.keys.signing, minimumSequence: lastSequence[mac.id])
            lastSequence[mac.id] = envelope.sequence
            let routes = advertisement.endpoints.sorted { $0.kind == .publicIPv6 && $1.kind != .publicIPv6 }.map {
                MacRoute(host: $0.host, port: $0.port, kind: $0.kind == .publicIPv6 ? .publicIPv6 : .manualPublicEndpoint, wanGateToken: advertisement.gateToken)
            }
            if let challenge = advertisement.verificationChallenge {
                let diagnostic = await verify(routes: routes, challenge: challenge, mac: mac, deviceID: deviceID, peer: peer)
                return RouteResult(routes: routes, diagnostic: diagnostic)
            }
            return RouteResult(routes: routes, diagnostic: routes.isEmpty ? "The Mac has no direct WAN endpoint." : nil)
        } catch { return RouteResult(routes: [], diagnostic: error.localizedDescription) }
    }

    private func verify(routes: [MacRoute], challenge: UUID, mac: PairedMac, deviceID: String, peer: RendezvousCapability) async -> String? {
        guard let identity = try? await MainActor.run(body: { try IPhoneIdentityProvider().loadOrCreate() }) else { return "The iPhone identity is unavailable." }
        var lastDiagnostic = "Turn off Wi-Fi so Clive can verify the route over cellular data."
        for route in routes {
            do {
                try await ReachabilityProbeClient().run(route: route, challenge: challenge, pinnedFingerprint: mac.certificateFingerprint, identity: identity.identity)
                try? await saveVerificationResult(.init(challenge: challenge, succeeded: true), mac: mac, deviceID: deviceID, peer: peer)
                return "Cellular access was verified."
            } catch { lastDiagnostic = error.localizedDescription }
        }
        try? await saveVerificationResult(.init(challenge: challenge, succeeded: false, diagnostic: lastDiagnostic), mac: mac, deviceID: deviceID, peer: peer)
        return lastDiagnostic
    }

    private func saveVerificationResult(_ result: RendezvousReachabilityResult, mac: PairedMac, deviceID: String, peer: RendezvousCapability) async throws {
        let envelope = try RendezvousCrypto.seal(result, senderID: deviceID, recipientID: mac.id, sequence: UInt64(Date.now.timeIntervalSince1970 * 1_000), expiresAt: .now.addingTimeInterval(120), recipientAgreementKey: peer.keys.agreement, senderSigningKey: keys.signingPrivateKey)
        try await cloud.save(envelope, recordName: RendezvousCrypto.recordName(macID: mac.id, deviceID: deviceID, purpose: "verification-result"), recordType: "ReachabilityResultV1")
    }

    private func sendReachabilityHint(mac: PairedMac, deviceID: String, peer: RendezvousCapability) async throws {
        let envelope = try RendezvousCrypto.seal(RendezvousReachabilityHint(), senderID: deviceID, recipientID: mac.id, sequence: UInt64(Date.now.timeIntervalSince1970 * 1_000), expiresAt: .now.addingTimeInterval(120), recipientAgreementKey: peer.keys.agreement, senderSigningKey: keys.signingPrivateKey)
        let name = RendezvousCrypto.recordName(macID: mac.id, deviceID: deviceID, purpose: "hint")
        try await cloud.save(envelope, recordName: name, recordType: "ReachabilityHintV1")
    }
}
