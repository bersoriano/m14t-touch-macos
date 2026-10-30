import CoreGraphics

struct TouchContact: Equatable {
    let id: Int
    let point: CGPoint
}

/// IOHID gesture phases, which differ from NSEvent.Phase raw values.
enum MagnifyPhase: Int64 {
    case began = 1, changed = 2, ended = 4, cancelled = 8
}

enum TouchAction: Equatable {
    case move(CGPoint)
    case down(CGPoint)
    case drag(CGPoint)
    case up(CGPoint)
    case scroll(at: CGPoint, dx: Double, dy: Double)
    case magnify(at: CGPoint, delta: Double, phase: MagnifyPhase)
}

struct TouchGestures {
    var pinchZoom: Bool = false
    private enum State {
        case idle
        case pending(first: TouchContact, latest: CGPoint, began: Double)
        case dragging(id: Int, last: CGPoint)
        case choosing(ids: Set<Int>, center: CGPoint, distance: Double)
        case scrolling(ids: Set<Int>, previous: CGPoint, anchor: CGPoint)
        case pinching(ids: Set<Int>, distance: Double, anchor: CGPoint)
        case suppressed
    }
    private var state: State = .idle
    private let chordDelay = 0.12
    private let dragThreshold = 1.5
    private let minimumPinchDistance = 20.0

    init(pinchZoom: Bool = false) {
        self.pinchZoom = pinchZoom
    }

    var isPending: Bool {
        if case .pending = state { return true }
        return false
    }

    mutating func update(_ contacts: [TouchContact], at time: Double, inputEnabled: Bool = true) -> [TouchAction] {
        // While video is unavailable, still acknowledge releases from USB HID.
        // No new gestures may start, but a completed lift permits the next one.
        guard inputEnabled else {
            let actions = interrupt()
            if contacts.isEmpty { state = .idle }
            return actions
        }
        let ids = Set(contacts.map(\.id))
        guard contacts.count <= 2, ids.count == contacts.count else {
            let actions = cancel()
            state = .suppressed
            return actions
        }
        if contacts.isEmpty {
            let actions: [TouchAction]
            switch state {
            case .pending(_, let latest, _): actions = [.down(latest), .up(latest)]
            case .dragging(_, let last): actions = [.up(last)]
            case .pinching(_, _, let anchor): actions = [.magnify(at: anchor, delta: 0, phase: .ended)]
            default: actions = []
            }
            state = .idle
            return actions
        }
        if case .suppressed = state { return [] }

        if contacts.count == 2 {
            let center = CGPoint(x: (contacts[0].point.x + contacts[1].point.x) / 2,
                                 y: (contacts[0].point.y + contacts[1].point.y) / 2)
            let distance = hypot(contacts[0].point.x - contacts[1].point.x,
                                 contacts[0].point.y - contacts[1].point.y)
            if case .pinching(let previousIDs, let previousDistance, let anchor) = state {
                guard previousIDs == ids, distance.isFinite, distance >= minimumPinchDistance else {
                    return interrupt()
                }
                state = .pinching(ids: ids, distance: distance, anchor: anchor)
                let delta = magnification(from: previousDistance, to: distance)
                return delta == 0 ? [] : [.magnify(at: anchor, delta: delta, phase: .changed)]
            }
            if case .choosing(let previousIDs, let origin, let initialDistance) = state {
                guard previousIDs == ids, distance.isFinite, distance >= minimumPinchDistance else {
                    return interrupt()
                }
                let travel = hypot(center.x - origin.x, center.y - origin.y)
                let spanChange = abs(distance - initialDistance)
                // Require deliberate separation change; a stationary first
                // finger and moving second finger can still form a pinch.
                if spanChange >= max(8, initialDistance * 0.04), spanChange > travel * 1.3 {
                    state = .pinching(ids: ids, distance: distance, anchor: origin)
                    return [.magnify(at: origin, delta: 0, phase: .began),
                            .magnify(at: origin, delta: magnification(from: initialDistance, to: distance), phase: .changed)]
                }
                // Span-dominated motion below the pinch threshold still looks
                // like a pinch. Do not prematurely classify a wide, one-sided
                // pinch as scrolling just because its midpoint also moves.
                guard travel >= 6, spanChange <= travel * 1.3 else { return [] }
                state = .scrolling(ids: ids, previous: center, anchor: origin)
                return [.scroll(at: origin, dx: center.x - origin.x, dy: center.y - origin.y)]
            }
            if case .scrolling(let previousIDs, let previous, let anchor) = state {
                guard previousIDs == ids else { state = .suppressed; return [] }
                state = .scrolling(ids: ids, previous: center, anchor: anchor)
                let dx = center.x - previous.x
                let dy = center.y - previous.y
                return dx == 0 && dy == 0 ? [] : [.scroll(at: anchor, dx: dx, dy: dy)]
            }
            var actions: [TouchAction] = []
            if case .dragging(_, let last) = state { actions.append(.up(last)) }
            if pinchZoom {
                guard distance.isFinite, distance >= minimumPinchDistance else {
                    state = .suppressed
                    return actions
                }
                state = .choosing(ids: ids, center: center, distance: distance)
            } else {
                state = .scrolling(ids: ids, previous: center, anchor: center)
            }
            actions.append(.move(center))
            return actions
        }

        let contact = contacts[0]
        switch state {
        case .idle:
            state = .pending(first: contact, latest: contact.point, began: time)
            return [.move(contact.point)]
        case .pending(let first, _, let began):
            guard first.id == contact.id else { state = .suppressed; return [] }
            guard time - began >= chordDelay else {
                state = .pending(first: first, latest: contact.point, began: began)
                return []
            }
            state = .dragging(id: contact.id, last: first.point)
            return [.down(first.point)] + update(contacts, at: time)
        case .dragging(let id, let last):
            guard id == contact.id else { state = .suppressed; return [.up(last)] }
            guard abs(contact.point.x - last.x) > dragThreshold || abs(contact.point.y - last.y) > dragThreshold else { return [] }
            state = .dragging(id: id, last: contact.point)
            return [.drag(contact.point)]
        case .pinching(_, _, let anchor):
            state = .suppressed
            return [.magnify(at: anchor, delta: 0, phase: .ended)]
        case .scrolling, .choosing:
            // A two-finger gesture never clicks when one finger lifts first.
            state = .suppressed
            return []
        case .suppressed:
            return []
        }
    }

    /// A pen entering proximity only interrupts an existing finger gesture.
    /// Idle fingers must be ready for their first tap after the pen leaves.
    mutating func interruptForPen() -> [TouchAction] {
        switch state {
        case .idle, .suppressed: return []
        default: return interrupt()
        }
    }

    mutating func cancel() -> [TouchAction] {
        defer { state = .idle }
        if case .dragging(_, let last) = state { return [.up(last)] }
        if case .pinching(_, _, let anchor) = state { return [.magnify(at: anchor, delta: 0, phase: .cancelled)] }
        return []
    }

    private func magnification(from previous: Double, to current: Double) -> Double {
        // Relative scale supports zooming both directions during one gesture.
        // Bound an individual HID jump so a bad sample cannot zoom wildly.
        min(0.5, max(-0.5, current / previous - 1))
    }

    /// After a bad frame, contact state is unknown. Release any button and wait
    /// for a valid all-fingers-up frame before allowing another click or drag.
    mutating func interrupt() -> [TouchAction] {
        let actions = cancel()
        state = .suppressed
        return actions
    }
}
