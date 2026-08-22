import CoreGraphics
import Foundation

enum TerminalPagerPage: Hashable {
    case leading
    case terminal(UUID)
    case trailing
}

enum TerminalPagerAction: Equatable {
    case select(UUID)
    case openDrawer(restoring: UUID)
    case createTerminal
    case restore(UUID)
}

struct TerminalPagerPolicy {
    static let horizontalThreshold: CGFloat = 44
    static let dominanceRatio: CGFloat = 1.25

    private var consumedBoundary: TerminalPagerPage?
    private var restorationTarget: UUID?

    static func horizontalDirection(translation: CGSize) -> HorizontalDirection? {
        guard abs(translation.width) >= horizontalThreshold,
              abs(translation.width) >= abs(translation.height) * dominanceRatio else { return nil }
        return translation.width > 0 ? .right : .left
    }

    mutating func transition(to page: TerminalPagerPage, terminalIDs: [UUID]) -> TerminalPagerAction? {
        guard let first = terminalIDs.first, let last = terminalIDs.last else { return nil }
        switch page {
        case .terminal(let id):
            if id != restorationTarget { consumedBoundary = nil; restorationTarget = nil }
            return .select(id)
        case .leading:
            guard consumedBoundary != .leading else { return .restore(first) }
            consumedBoundary = .leading; restorationTarget = first
            return .openDrawer(restoring: first)
        case .trailing:
            guard consumedBoundary != .trailing else { return .restore(last) }
            consumedBoundary = .trailing; restorationTarget = last
            return .createTerminal
        }
    }
}

enum HorizontalDirection: Equatable { case left, right }
