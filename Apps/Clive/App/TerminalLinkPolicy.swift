import Foundation

enum TerminalLinkPolicy {
    static func destination(for link: String) -> URL? {
        guard let components = URLComponents(string: link),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            return nil
        }
        return components.url
    }
}
