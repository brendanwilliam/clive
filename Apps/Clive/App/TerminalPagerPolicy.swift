import CoreGraphics
import Foundation

enum TerminalTitleSwipeDirection: Equatable {
    case left
    case right
}

struct TerminalTitleNavigationPolicy {
    static let horizontalThreshold: CGFloat = 44
    static let dominanceRatio: CGFloat = 1.25

    static func direction(translation: CGSize) -> TerminalTitleSwipeDirection? {
        guard abs(translation.width) >= horizontalThreshold,
              abs(translation.width) >= abs(translation.height) * dominanceRatio else { return nil }
        return translation.width > 0 ? .right : .left
    }

    static func adjacentTerminal(from selectedID: UUID?, terminalIDs: [UUID], direction: TerminalTitleSwipeDirection) -> UUID? {
        guard let selectedID, let index = terminalIDs.firstIndex(of: selectedID) else { return nil }
        switch direction {
        case .left:
            let next = terminalIDs.index(after: index)
            return next < terminalIDs.endIndex ? terminalIDs[next] : nil
        case .right:
            return index > terminalIDs.startIndex ? terminalIDs[terminalIDs.index(before: index)] : nil
        }
    }
}

enum TerminalContentTapRegion: Equatable {
    case up
    case enter
    case down
}

enum TerminalContentGesturePolicy {
    static func region(forDoubleTapAt y: CGFloat, height: CGFloat) -> TerminalContentTapRegion? {
        guard height > 0, y >= 0, y <= height else { return nil }
        if y < height / 3 { return .up }
        if y > height * 2 / 3 { return .down }
        return .enter
    }

    static func input(for region: TerminalContentTapRegion) -> Data {
        switch region {
        case .up: Data("\u{1b}[A".utf8)
        case .enter: Data("\r".utf8)
        case .down: Data("\u{1b}[B".utf8)
        }
    }
}
