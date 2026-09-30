import UIKit

/// Direction and touch behavior shared by controls that present a four-way wheel.
enum ActionWheelDirection: CaseIterable, Equatable {
    case up, down, left, right

    static func forDisplacement(_ point: CGPoint) -> Self {
        let angle = atan2(point.y, point.x)
        if angle >= -.pi / 4, angle < .pi / 4 { return .right }
        if angle >= .pi / 4, angle < 3 * .pi / 4 { return .down }
        if angle >= 3 * .pi / 4 || angle < -3 * .pi / 4 { return .left }
        return .up
    }
}

enum ActionWheelResult: Equatable {
    case primary
    case direction(ActionWheelDirection)
}

struct ActionWheelGesture {
    static let holdDuration: TimeInterval = 0.35
    private(set) var isActive = false
    private(set) var selection: ActionWheelDirection?
    private(set) var didSwipe = false
    private var beganAt: TimeInterval = 0

    mutating func begin(at time: TimeInterval) {
        isActive = true
        selection = nil
        didSwipe = false
        beganAt = time
    }

    func canPresentWheel(at time: TimeInterval) -> Bool {
        isActive && time - beganAt >= Self.holdDuration
    }

    mutating func move(_ displacement: CGPoint) {
        guard isActive else { return }
        let distance = hypot(displacement.x, displacement.y)
        if distance > 8 { didSwipe = true }
        if distance <= 24 {
            selection = nil
        } else {
            selection = ActionWheelDirection.forDisplacement(displacement)
        }
    }

    mutating func end(_ displacement: CGPoint, at time: TimeInterval) -> ActionWheelResult? {
        guard isActive else { return nil }
        move(displacement)
        let result: ActionWheelResult?
        if let selection {
            result = .direction(selection)
        } else if !didSwipe && time - beganAt <= Self.holdDuration {
            result = .primary
        } else {
            result = nil
        }
        cancel()
        return result
    }

    mutating func cancel() {
        isActive = false
        selection = nil
        didSwipe = false
    }
}

struct ActionWheelPreview {
    let direction: ActionWheelDirection?
    let displacement: CGPoint
}

/// Owns one continuous touch. The host places ActionWheelView above this control.
final class ActionWheelControl: UIButton {
    var onPreview: ((ActionWheelPreview?) -> Void)?
    var onResult: ((ActionWheelResult) -> Void)?
    private(set) var gesture = ActionWheelGesture()
    private let feedback = UISelectionFeedbackGenerator()
    private var presentationTask: DispatchWorkItem?
    private var wheelPresented = false
    private var initialTouchPoint: CGPoint = .zero
    private var latestTouchPoint: CGPoint = .zero
    private var cueViews: [UIImageView] = []

    override func accessibilityActivate() -> Bool {
        onResult?(.primary)
        return true
    }

    func setDirectionalCueVisible(_ visible: Bool) {
        if cueViews.isEmpty {
            for symbol in ["chevron.up", "chevron.down", "chevron.left", "chevron.right"] {
                let view = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)))
                view.tintColor = UIColor.black.withAlphaComponent(0.42)
                view.isUserInteractionEnabled = false
                view.isAccessibilityElement = false
                addSubview(view)
                cueViews.append(view)
            }
        }
        cueViews.forEach { $0.isHidden = !visible }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard cueViews.count == 4 else { return }
        let positions = [CGPoint(x: bounds.midX, y: 9), CGPoint(x: bounds.midX, y: bounds.maxY - 9),
                         CGPoint(x: 12, y: bounds.midY), CGPoint(x: bounds.maxX - 12, y: bounds.midY)]
        for (view, position) in zip(cueViews, positions) {
            view.sizeToFit()
            view.center = position
        }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard super.beginTracking(touch, with: event) else { return false }
        gesture.begin(at: touch.timestamp)
        initialTouchPoint = touch.location(in: self)
        latestTouchPoint = initialTouchPoint
        feedback.prepare()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.gesture.canPresentWheel(at: ProcessInfo.processInfo.systemUptime) else { return }
            self.wheelPresented = true
            self.onPreview?(ActionWheelPreview(direction: self.gesture.selection, displacement: self.displacement(for: self.latestTouchPoint)))
        }
        presentationTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + ActionWheelGesture.holdDuration, execute: task)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        latestTouchPoint = touch.location(in: self)
        let previousSelection = gesture.selection
        gesture.move(displacement(for: latestTouchPoint))
        if gesture.selection != previousSelection, gesture.selection != nil { feedback.selectionChanged() }
        if wheelPresented { onPreview?(ActionWheelPreview(direction: gesture.selection, displacement: displacement(for: latestTouchPoint))) }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        let result = touch.flatMap { gesture.end(displacement(for: $0.location(in: self)), at: $0.timestamp) }
        cancelWheel()
        if let result { onResult?(result) }
        super.endTracking(touch, with: event)
    }

    override func cancelTracking(with event: UIEvent?) {
        cancelWheel()
        super.cancelTracking(with: event)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelWheel() }
    }

    func cancelWheel() {
        presentationTask?.cancel()
        presentationTask = nil
        gesture.cancel()
        dismissWheel()
    }

    private func dismissWheel() {
        guard wheelPresented else { return }
        wheelPresented = false
        onPreview?(nil)
    }

    private func displacement(for point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - initialTouchPoint.x, y: point.y - initialTouchPoint.y)
    }
}

/// A noninteractive 160-point overlay. The host converts touch points into this view.
final class ActionWheelView: UIView {
    static let diameter: CGFloat = 160
    private let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let dragLine = CAShapeLayer()
    private var segments: [ActionWheelDirection: CAShapeLayer] = [:]
    private(set) var selectedDirection: ActionWheelDirection?
    var segmentCount: Int { segments.count }
    var hasVisibleDragLine: Bool { !dragLine.isHidden }
    func segmentBounds(for direction: ActionWheelDirection) -> CGRect? { segments[direction]?.path?.boundingBoxOfPath }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        if #available(iOS 26.0, *) { material.effect = UIGlassEffect(style: .regular) }
        material.frame = bounds
        material.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        material.layer.cornerRadius = 80
        material.layer.cornerCurve = .continuous
        material.clipsToBounds = true
        addSubview(material)
        for (direction, symbol, angle, point) in [
            (ActionWheelDirection.up, "arrow.up", -CGFloat.pi / 2, CGPoint(x: 80, y: 32)),
            (.down, "arrow.down", CGFloat.pi / 2, CGPoint(x: 80, y: 128)),
            (.left, "arrow.left", CGFloat.pi, CGPoint(x: 32, y: 80)),
            (.right, "arrow.right", CGFloat.zero, CGPoint(x: 128, y: 80)),
        ] {
            let segment = CAShapeLayer()
            let center = CGPoint(x: 80, y: 80)
            let path = UIBezierPath()
            path.addArc(withCenter: center, radius: 76, startAngle: angle - .pi / 4, endAngle: angle + .pi / 4, clockwise: true)
            path.addArc(withCenter: center, radius: 24, startAngle: angle + .pi / 4, endAngle: angle - .pi / 4, clockwise: false)
            path.close()
            segment.path = path.cgPath
            segment.lineWidth = 1
            material.contentView.layer.addSublayer(segment)
            segments[direction] = segment
            let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)))
            icon.tintColor = .label
            icon.sizeToFit()
            icon.center = point
            material.contentView.addSubview(icon)
        }
        dragLine.lineWidth = 3
        dragLine.lineCap = .round
        dragLine.fillColor = nil
        dragLine.isHidden = true
        material.contentView.layer.addSublayer(dragLine)
        let cancelIcon = UIImageView(image: UIImage(systemName: "x.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .regular)))
        cancelIcon.tintColor = .secondaryLabel
        cancelIcon.accessibilityIdentifier = "action-wheel-cancel"
        cancelIcon.sizeToFit()
        cancelIcon.center = CGPoint(x: 80, y: 80)
        material.contentView.addSubview(cancelIcon)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ActionWheelView, _) in
            view.updateColors()
        }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(direction: ActionWheelDirection?, finger: CGPoint) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let displacement = CGPoint(x: finger.x - center.x, y: finger.y - center.y)
        let distance = hypot(displacement.x, displacement.y)
        selectedDirection = distance > 24 && direction != nil ? ActionWheelDirection.forDisplacement(displacement) : nil
        if distance > 3 {
            let scale = min(1, 76 / distance)
            let end = CGPoint(x: center.x + displacement.x * scale, y: center.y + displacement.y * scale)
            let path = UIBezierPath()
            path.move(to: center)
            path.addLine(to: end)
            dragLine.path = path.cgPath
            dragLine.isHidden = false
        } else {
            dragLine.isHidden = true
        }
        updateColors()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateColors()
    }

    private func updateColors() {
        for (direction, segment) in segments {
            segment.fillColor = (selectedDirection == direction ? tintColor.withAlphaComponent(0.36) : UIColor.label.withAlphaComponent(0.06)).cgColor
            segment.strokeColor = UIColor.separator.withAlphaComponent(0.65).cgColor
        }
        dragLine.strokeColor = tintColor.withAlphaComponent(0.9).cgColor
    }
}
