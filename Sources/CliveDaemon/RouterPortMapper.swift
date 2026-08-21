import Darwin
import Foundation
import CliveCore
import Security
import SystemConfiguration

struct RouterMapping: Equatable, Sendable {
    enum Method: String, Sendable { case pcp = "PCP", natPMP = "NAT-PMP" }
    let host: String
    let externalPort: UInt16
    let internalPort: UInt16
    let lifetime: UInt32
    let method: Method
}

enum RouterPortMappingError: LocalizedError {
    case noGateway, unsupported, invalidResponse, privateExternalAddress
    var errorDescription: String? {
        switch self {
        case .noGateway: "The default router could not be detected."
        case .unsupported: "This router did not accept PCP or NAT-PMP port mapping."
        case .invalidResponse: "The router returned an invalid port-mapping response."
        case .privateExternalAddress: "The router has no public IPv4 address (CGNAT or double NAT). Use public IPv6, a private VPN, or manual upstream forwarding."
        }
    }
}

final class RouterPortMapper: @unchecked Sendable {
    private let nonce: Data
    init() {
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        nonce = Data(bytes)
    }

    func open(internalPort: UInt16, suggestedExternalPort: UInt16? = nil, lifetime: UInt32 = 3600) throws -> RouterMapping {
        let gateway = try defaultGateway()
        if let mapping = try? pcp(gateway: gateway, internalPort: internalPort, externalPort: suggestedExternalPort ?? internalPort, lifetime: lifetime) { return mapping }
        return try natPMP(gateway: gateway, internalPort: internalPort, externalPort: suggestedExternalPort ?? internalPort, lifetime: lifetime)
    }

    func close(_ mapping: RouterMapping) {
        guard let gateway = try? defaultGateway() else { return }
        switch mapping.method {
        case .pcp: _ = try? pcp(gateway: gateway, internalPort: mapping.internalPort, externalPort: mapping.externalPort, lifetime: 0)
        case .natPMP: _ = try? natPMP(gateway: gateway, internalPort: mapping.internalPort, externalPort: mapping.externalPort, lifetime: 0)
        }
    }

    private func defaultGateway() throws -> String {
        guard let store = SCDynamicStoreCreate(nil, "com.clive.router" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let router = value["Router"] as? String, !router.isEmpty else { throw RouterPortMappingError.noGateway }
        return router
    }

    private func pcp(gateway: String, internalPort: UInt16, externalPort: UInt16, lifetime: UInt32) throws -> RouterMapping {
        var request = Data([2, 1, 0, 0]); request.appendUInt32(lifetime)
        request.append(try pcpClientAddress()); request.append(nonce); request.append(6); request.append(Data(repeating: 0, count: 3))
        request.appendUInt16(internalPort); request.appendUInt16(externalPort); request.append(Data(repeating: 0, count: 16))
        let response = try exchange(request, gateway: gateway)
        return try Self.parsePCPResponse(response, nonce: nonce, internalPort: internalPort)
    }

    static func parsePCPResponse(_ response: Data, nonce: Data, internalPort: UInt16) throws -> RouterMapping {
        guard response.count >= 60, response[0] == 2, response[1] == 0x81, response[3] == 0,
              response.subdata(in: 24..<36) == nonce else { throw RouterPortMappingError.unsupported }
        let port = response.uint16(at: 42); let host = try formatAddress(response.subdata(in: 44..<60)); try validatePublic(host)
        return RouterMapping(host: host, externalPort: port, internalPort: internalPort, lifetime: response.uint32(at: 4), method: .pcp)
    }

    private func natPMP(gateway: String, internalPort: UInt16, externalPort: UInt16, lifetime: UInt32) throws -> RouterMapping {
        let addressResponse = try exchange(Data([0, 0]), gateway: gateway)
        let host = try Self.parseNATPMPAddressResponse(addressResponse)
        var request = Data([0, 2, 0, 0]); request.appendUInt16(internalPort); request.appendUInt16(externalPort); request.appendUInt32(lifetime)
        let response = try exchange(request, gateway: gateway)
        return try Self.parseNATPMPMappingResponse(response, host: host, internalPort: internalPort)
    }

    static func parseNATPMPAddressResponse(_ response: Data) throws -> String {
        guard response.count >= 12, response[0] == 0, response[1] == 128, response.uint16(at: 2) == 0 else { throw RouterPortMappingError.unsupported }
        let host = response[8..<12].map(String.init).joined(separator: "."); try validatePublic(host); return host
    }

    static func parseNATPMPMappingResponse(_ response: Data, host: String, internalPort: UInt16) throws -> RouterMapping {
        guard response.count >= 16, response[0] == 0, response[1] == 130, response.uint16(at: 2) == 0 else { throw RouterPortMappingError.unsupported }
        return RouterMapping(host: host, externalPort: response.uint16(at: 10), internalPort: internalPort, lifetime: response.uint32(at: 12), method: .natPMP)
    }

    private func exchange(_ request: Data, gateway: String) throws -> Data {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP); guard descriptor >= 0 else { throw RouterPortMappingError.unsupported }
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(5351).bigEndian
        guard inet_pton(AF_INET, gateway, &address.sin_addr) == 1 else { throw RouterPortMappingError.noGateway }
        let sent = request.withUnsafeBytes { bytes in withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        guard sent == request.count else { throw RouterPortMappingError.unsupported }
        var response = [UInt8](repeating: 0, count: 128)
        let count = recv(descriptor, &response, response.count, 0); guard count > 0 else { throw RouterPortMappingError.unsupported }
        return Data(response.prefix(count))
    }

    private static func formatAddress(_ data: Data) throws -> String {
        guard data.count == 16 else { throw RouterPortMappingError.invalidResponse }
        if data.prefix(10).allSatisfy({ $0 == 0 }) && data[10] == 0xff && data[11] == 0xff { return data[12..<16].map(String.init).joined(separator: ".") }
        var address = in6_addr(); _ = withUnsafeMutableBytes(of: &address) { data.copyBytes(to: $0) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { throw RouterPortMappingError.invalidResponse }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func pcpClientAddress() throws -> Data {
        guard let value = PrivateNetwork.eligibleAddresses().first(where: { $0.contains(".") }) else { throw RouterPortMappingError.noGateway }
        var ipv4 = in_addr(); guard inet_pton(AF_INET, value, &ipv4) == 1 else { throw RouterPortMappingError.noGateway }
        var result = Data(repeating: 0, count: 10); result.append(contentsOf: [0xff, 0xff])
        withUnsafeBytes(of: ipv4.s_addr) { result.append(contentsOf: $0) }
        return result
    }

    private static func validatePublic(_ host: String) throws {
        let privatePrefixes = ["10.", "192.168.", "127.", "100.64.", "100.65.", "100.66.", "100.67.", "100.68.", "100.69.", "100.70.", "100.71.", "100.72.", "100.73.", "100.74.", "100.75.", "100.76.", "100.77.", "100.78.", "100.79.", "100.80.", "100.81.", "100.82.", "100.83.", "100.84.", "100.85.", "100.86.", "100.87.", "100.88.", "100.89.", "100.90.", "100.91.", "100.92.", "100.93.", "100.94.", "100.95.", "100.96.", "100.97.", "100.98.", "100.99.", "100.100.", "100.101.", "100.102.", "100.103.", "100.104.", "100.105.", "100.106.", "100.107.", "100.108.", "100.109.", "100.110.", "100.111.", "100.112.", "100.113.", "100.114.", "100.115.", "100.116.", "100.117.", "100.118.", "100.119.", "100.120.", "100.121.", "100.122.", "100.123.", "100.124.", "100.125.", "100.126.", "100.127.", "172.16.", "172.17.", "172.18.", "172.19.", "172.20.", "172.21.", "172.22.", "172.23.", "172.24.", "172.25.", "172.26.", "172.27.", "172.28.", "172.29.", "172.30.", "172.31."]
        if privatePrefixes.contains(where: host.hasPrefix) { throw RouterPortMappingError.privateExternalAddress }
    }
}
