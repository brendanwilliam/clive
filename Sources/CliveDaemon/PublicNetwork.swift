import Darwin
import Foundation

enum PublicNetwork {
    static func publicIPv6Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var values: Set<String> = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard (interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING)) == UInt32(IFF_UP | IFF_RUNNING),
                  let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in6>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let bare = value.components(separatedBy: "%")[0]
            var parsed = in6_addr(); guard inet_pton(AF_INET6, bare, &parsed) == 1 else { continue }
            let isGlobal = withUnsafeBytes(of: parsed) { bytes in
                bytes[0] != 0xff && (bytes[0] & 0xfe) != 0xfc && !(bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) && !bytes.dropLast().allSatisfy { $0 == 0 }
            }
            if isGlobal { values.insert(bare) }
        }
        return values.sorted()
    }
}
