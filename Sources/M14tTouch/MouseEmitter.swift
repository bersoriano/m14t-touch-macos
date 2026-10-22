import CoreGraphics
import Foundation

/// Posts synthetic mouse events into macOS.
///
/// Wrapping `CGEvent` here keeps the driver's touch logic free of CoreGraphics
/// boilerplate and gives a single, obvious place where system events originate —
/// which matters because posting these requires Accessibility permission.
struct MouseEmitter {
    /// Native tablet fields follow the upstream pen emitter. Keep construction
    /// separate from posting so replay checks never inject system input.
    func makePenEvent(_ action: PenAction) -> CGEvent? {
        switch action {
        case .proximity(let point, let entering, let eraser):
            guard let event = CGEvent(source: nil) else { return nil }
            event.type = .tabletProximity
            event.location = point
            event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
            event.setIntegerValueField(.tabletProximityEventPointerType, value: eraser ? 3 : 1)
            event.setIntegerValueField(.tabletProximityEventVendorID, value: 0x056a)
            event.setIntegerValueField(.tabletProximityEventDeviceID, value: 1)
            event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x07ff)
            return event
        case .pointer(let type, let button, let point, let pressure, let tilt):
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: button) else { return nil }
            event.setIntegerValueField(.mouseEventSubtype, value: 1)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setIntegerValueField(.tabletEventDeviceID, value: 1)
            // Tablet-aware drawing apps use the tablet button mask as well as
            // the mouse event type. Keep contact held throughout the stroke.
            let buttons: Int64
            switch type {
            case .leftMouseDown, .leftMouseDragged: buttons = 1
            case .rightMouseDown, .rightMouseDragged: buttons = 2
            default: buttons = 0
            }
            event.setIntegerValueField(.tabletEventPointButtons, value: buttons)
            event.setDoubleValueField(.mouseEventPressure, value: pressure)
            event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
            event.setDoubleValueField(.tabletEventTiltX, value: tilt.x)
            event.setDoubleValueField(.tabletEventTiltY, value: tilt.y)
            return event
        }
    }

    func postPen(_ actions: [PenAction]) {
        for action in actions { makePenEvent(action)?.post(tap: .cghidEventTap) }
    }


    /// Pixel scroll deltas follow finger motion (direct-manipulation direction).
    /// Keep the event at the gesture's starting point so its target stays fixed.
    func scroll(at point: CGPoint, dx: Int32, dy: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    /// Emit a left-button event (down, up, or drag) at a screen point.
    func post(_ type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            FileHandle.standardError.write(
                Data("⚠️  CGEvent creation failed — is Accessibility permission granted?\n".utf8)
            )
            return
        }
        event.post(tap: .cghidEventTap)
    }
}
