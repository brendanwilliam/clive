import Darwin
import Foundation

enum PrivateNetwork {
    static func eligibleAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [(interface: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard (interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING)) == UInt32(IFF_UP | IFF_RUNNING),
                  let name = interface.ifa_name.map({ String(cString: $0) }),
                  let address = interface.ifa_addr else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length: socklen_t = address.pointee.sa_family == UInt8(AF_INET) ? socklen_t(MemoryLayout<sockaddr_in>.size) : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6),
                  getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if isPrivate(value) { result.append((name, value)) }
        }
        var addressesByValue: [String: String] = [:]
        for candidate in result {
            if let current = addressesByValue[candidate.address], interfacePriority(current) <= interfacePriority(candidate.interface) { continue }
            addressesByValue[candidate.address] = candidate.interface
        }
        return addressesByValue.map { (interface: $0.value, address: $0.key) }.sorted {
            let left = endpointPriority($0.address, interface: $0.interface)
            let right = endpointPriority($1.address, interface: $1.interface)
            return left == right ? $0.address < $1.address : left < right
        }.map(\.address)
    }

    static func isPrivate(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let value = UInt32(bigEndian: v4.s_addr)
            // RFC1918, loopback for local integration, and RFC6598 carrier-grade/overlay space.
            return value >> 24 == 10 || value >> 20 == 0xac1 || value >> 16 == 0xc0a8 || value >> 24 == 127 || value >> 22 == 0x191
        }
        var v6 = in6_addr()
        let bare = address.components(separatedBy: "%")[0]
        if inet_pton(AF_INET6, bare, &v6) == 1 {
            return withUnsafeBytes(of: v6) { bytes in
                let first = bytes[0]
                return (first & 0xfe) == 0xfc || (first == 0xfe && (bytes[1] & 0xc0) == 0x80) || bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            }
        }
        return false
    }

    /// Pairing tickets must prefer an address reachable from another LAN device. Loopback is
    /// retained for localhost integration tests, but must never win while a LAN address exists.
    private static func endpointPriority(_ address: String, interface: String) -> Int {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let value = UInt32(bigEndian: v4.s_addr)
            if value >> 24 == 127 { return 30 }
            return interfacePriority(interface)
        }
        let bare = address.components(separatedBy: "%")[0]
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, bare, &v6) == 1 else { return 4 }
        return withUnsafeBytes(of: v6) { bytes in
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return 30 }
            if (bytes[0] & 0xfe) == 0xfc { return 10 + interfacePriority(interface) }
            return 20 + interfacePriority(interface)
        }
    }

    private static func interfacePriority(_ interface: String) -> Int {
        if interface == "en0" { return 0 }
        if interface.hasPrefix("en") { return 1 }
        if interface.hasPrefix("utun") || interface == "awdl0" || interface == "llw0" { return 5 }
        return 3
    }
}
