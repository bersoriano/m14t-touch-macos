import CoreGraphics

enum PenAction: Equatable {
    case proximity(CGPoint, entering: Bool, eraser: Bool)
    case pointer(type: CGEventType, button: CGMouseButton, point: CGPoint, pressure: Double, tilt: CGPoint)

    var eventType: CGEventType? {
        if case .pointer(let type, _, _, _, _) = self { return type }
        return nil
    }
}

/// Immediate pen input, independent of the finger chord delay and calibration.
struct PenInput {
    private(set) var isInRange = false
    private var held: CGMouseButton?
    private var lastPoint = CGPoint.zero
    private var eraser = false
    private var waitingForLift = false

    mutating func update(_ sample: PenReport, at point: CGPoint, inputEnabled: Bool = true) -> [PenAction] {
        guard inputEnabled else {
            let actions = interrupt()
            if !sample.touching && !sample.barrel { waitingForLift = false }
            return actions
        }
        guard sample.inRange else { return cancel() }
        if waitingForLift {
            guard !sample.touching && !sample.barrel else { return [] }
            waitingForLift = false
        }
        var actions: [PenAction] = []
        if isInRange && eraser != sample.eraser { actions += cancel() }
        lastPoint = point
        if !isInRange {
            isInRange = true
            eraser = sample.eraser
            actions.append(.proximity(point, entering: true, eraser: eraser))
        }
        let wanted: CGMouseButton? = sample.barrel ? .right : (sample.touching ? .left : nil)
        if held != wanted, let previous = held {
            actions.append(pointer(previous == .left ? .leftMouseUp : .rightMouseUp, previous))
            held = nil
        }
        if let button = wanted {
            let type: CGEventType
            if held == nil { type = button == .left ? .leftMouseDown : .rightMouseDown }
            else { type = button == .left ? .leftMouseDragged : .rightMouseDragged }
            held = button
            actions.append(.pointer(type: type, button: button, point: point,
                pressure: button == .left ? sample.pressure : 0, tilt: sample.tilt))
        } else {
            actions.append(.pointer(type: .mouseMoved, button: .left, point: point, pressure: 0, tilt: sample.tilt))
        }
        return actions
    }

    mutating func cancel() -> [PenAction] {
        var actions: [PenAction] = []
        if let button = held { actions.append(pointer(button == .left ? .leftMouseUp : .rightMouseUp, button)) }
        if isInRange { actions.append(.proximity(lastPoint, entering: false, eraser: eraser)) }
        held = nil
        isInRange = false
        waitingForLift = false
        return actions
    }

    mutating func interrupt() -> [PenAction] {
        let actions = cancel()
        waitingForLift = true
        return actions
    }

    private func pointer(_ type: CGEventType, _ button: CGMouseButton) -> PenAction {
        .pointer(type: type, button: button, point: lastPoint, pressure: 0, tilt: .zero)
    }
}
