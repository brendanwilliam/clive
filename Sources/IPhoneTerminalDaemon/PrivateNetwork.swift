import Darwin
import Foundation

enum PrivateNetwork {
    static func eligibleAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard (interface.ifa_flags & UInt32(IFF_UP)) != 0, let address = interface.ifa_addr else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length: socklen_t = address.pointee.sa_family == UInt8(AF_INET) ? socklen_t(MemoryLayout<sockaddr_in>.size) : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6),
                  getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: host)
            if isPrivate(value) { result.append(value.components(separatedBy: "%")[0]) }
        }
        return Array(Set(result)).sorted()
    }

    static func isPrivate(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let value = UInt32(bigEndian: v4.s_addr)
            return value >> 24 == 10 || value >> 20 == 0xac1 || value >> 16 == 0xc0a8 || value >> 24 == 127
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
}
