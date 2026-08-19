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
        let identifier = Bundle.main.object(forInfoDictionaryKey: "CliveCloudContainer") as? String ?? "iCloud.com.clive"
        cloud = CloudRendezvousStore(containerIdentifier: identifier)
        keys = try RendezvousKeyStore(service: "com.clive.iphone.rendezvous").loadOrCreate()
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
            return RouteResult(routes: routes, diagnostic: routes.isEmpty ? "The Mac has no direct WAN endpoint." : nil)
        } catch { return RouteResult(routes: [], diagnostic: error.localizedDescription) }
    }

    private func sendReachabilityHint(mac: PairedMac, deviceID: String, peer: RendezvousCapability) async throws {
        let envelope = try RendezvousCrypto.seal(RendezvousReachabilityHint(), senderID: deviceID, recipientID: mac.id, sequence: UInt64(Date.now.timeIntervalSince1970 * 1_000), expiresAt: .now.addingTimeInterval(120), recipientAgreementKey: peer.keys.agreement, senderSigningKey: keys.signingPrivateKey)
        let name = RendezvousCrypto.recordName(macID: mac.id, deviceID: deviceID, purpose: "hint")
        try await cloud.save(envelope, recordName: name, recordType: "ReachabilityHintV1")
    }
}
