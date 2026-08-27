import Foundation
import Network

enum MacRouteKind: String, Equatable, Sendable { case lan, privateVPN, publicIPv6, manualPublicEndpoint }
struct MacRoute: Equatable, Sendable {
    let host: String; let port: UInt16; let kind: MacRouteKind; let wanGateToken: Data?
    init(host: String, port: UInt16, kind: MacRouteKind = .lan, wanGateToken: Data? = nil) { self.host = host; self.port = port; self.kind = kind; self.wanGateToken = wanGateToken }
}

final class BonjourDiscovery: NSObject, @unchecked Sendable, NetServiceBrowserDelegate, NetServiceDelegate {
    var onChange: (([String: MacRoute]) -> Void)?
    private let browser = NetServiceBrowser()
    private let monitorQueue = DispatchQueue(label: "com.clive.bonjour-path")
    private var wifiPathMonitor: NWPathMonitor?
    private var services: [NetService] = []
    private var routes: [String: MacRoute] = [:]

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_iphone-term._tcp.", inDomain: "local.")
        let wifiPathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
        self.wifiPathMonitor = wifiPathMonitor
        wifiPathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self, path.status != .satisfied else { return }
            DispatchQueue.main.async { self.clearRoutes() }
        }
        wifiPathMonitor.start(queue: monitorQueue)
    }

    func stop() {
        wifiPathMonitor?.cancel(); wifiPathMonitor = nil
        browser.stop(); services.forEach { $0.stop() }; services.removeAll(); clearRoutes()
    }

    private func clearRoutes() {
        guard !routes.isEmpty else { return }
        routes.removeAll(); onChange?([:])
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) { services.append(service); service.delegate = self; service.resolve(withTimeout: 5) }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 === service }
        if let id = serviceID(service) { routes.removeValue(forKey: id); onChange?(routes) }
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let id = serviceID(sender), let host = sender.hostName, sender.port > 0, sender.port <= Int(UInt16.max) else { return }
        routes[id] = MacRoute(host: host, port: UInt16(sender.port)); onChange?(routes)
    }
    private func serviceID(_ service: NetService) -> String? {
        guard let data = service.txtRecordData(), let value = NetService.dictionary(fromTXTRecord: data)["id"] else { return nil }
        return String(data: value, encoding: .utf8)
    }
}
