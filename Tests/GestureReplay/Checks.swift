import CoreGraphics
#if SWIFT_PACKAGE
@testable import M14tTouch
#endif

/// Shared scenarios for XCTest and the Command Line Tools-only runner.
func runGestureReplayChecks(_ check: (Bool, String) -> Void) {
    func contact(_ id: Int, _ x: Double, _ y: Double) -> TouchContact {
        TouchContact(id: id, point: CGPoint(x: x, y: y))
    }
    func report(_ contacts: [TouchContact]) -> [UInt8] {
        // Gen 1 descriptor: ID, reserved byte, count, five 7-byte contacts, scan time.
        var bytes = [UInt8](repeating: 0, count: 40)
        bytes[0] = 0x0c
        bytes[2] = UInt8(contacts.count)
        for (slot, contact) in contacts.enumerated() {
            let offset = 3 + slot * 7
            bytes[offset] = 0x05 // Tip Switch + Confidence
            for (index, value) in [contact.id, Int(contact.point.x), Int(contact.point.y)].enumerated() {
                bytes[offset + 1 + index * 2] = UInt8(value & 255)
                bytes[offset + 2 + index * 2] = UInt8((value >> 8) & 255)
            }
        }
        return bytes
    }
    let p = CGPoint(x: 300, y: 1400)
    let first = contact(1, 300, 1400)
    let second = contact(2, 500, 1400)

    // Decode whole reports, never combine partial X/Y values from different fingers.
    let raw = [contact(7, 12300, 6950), contact(258, 5000, 3200)]
    check(M14tReport.decode(report(raw)) == raw, "decode separate contacts and 16-bit IDs")
    check(M14tReport.decode(report([])) == [], "empty report releases fingers")
    check(M14tReport.decode([0x0c, 0]) == nil, "reject truncated report")
    var wrong = report(raw); wrong[0] = 0x20
    check(M14tReport.decode(wrong) == nil, "ignore secondary interface and pen")
    var malformed = report(raw); malformed[2] = 6
    check(M14tReport.decode(malformed) == nil, "reject impossible contact count")
    var mismatch = report(raw); mismatch[2] = 1
    check(M14tReport.decode(mismatch) == nil, "reject incomplete or inconsistent frame")
    check(M14tReport.decode(report([first, first])) == nil, "reject duplicate contact IDs")
    var palm = report([first]); palm[3] = 1
    check(M14tReport.decode(palm) == [], "ignore unconfident palm contact")
    var lifted = report([first]); lifted[3] = 4
    check(M14tReport.decode(lifted) == [], "lift report releases even if count still includes lifted slot")

    var gesture = TouchGestures()
    check(gesture.update([first], at: 0) == [.move(p)], "first touch moves cursor without clicking")
    check(gesture.update([], at: 0.05) == [.down(p), .up(p)], "short single tap clicks once")
    check(gesture.update([], at: 0.06).isEmpty, "release does not repeat click")

    gesture = TouchGestures()
    _ = gesture.update([first], at: 0)
    check(gesture.update([first], at: 0.13) == [.down(p)], "hold starts drag after gesture grace period")
    let moved = contact(1, 320, 1450)
    check(gesture.update([moved], at: 0.14) == [.drag(moved.point)], "one-finger drag uses complete coordinate pair")
    check(gesture.update([], at: 0.15) == [.up(moved.point)], "drag releases at last position")

    gesture = TouchGestures()
    _ = gesture.update([first], at: 0)
    let center = CGPoint(x: 400, y: 1400)
    check(gesture.update([first, second], at: 0.05) == [.move(center)], "second finger cancels pending click")
    check(gesture.update([contact(2, 515, 1430), contact(1, 315, 1430)], at: 0.07)
          == [.scroll(at: center, dx: 15, dy: 30)], "two-finger scroll follows centroid regardless of slot order")
    check(gesture.update([contact(1, 315, 1430)], at: 0.08).isEmpty, "lifting one scrolling finger must not click")
    check(gesture.update([contact(1, 320, 1440)], at: 0.2).isEmpty, "remaining finger stays suppressed")
    check(gesture.update([], at: 0.3).isEmpty, "all fingers lifted resets scrolling")
    _ = gesture.update([first], at: 0.4)
    check(gesture.update([], at: 0.45) == [.down(p), .up(p)], "tap works again after scroll")

    gesture = TouchGestures()
    _ = gesture.update([first], at: 0)
    _ = gesture.update([first], at: 0.13)
    check(gesture.update([first, second], at: 0.2) == [.up(p), .move(center)], "second finger releases existing drag before scrolling")
    check(gesture.cancel().isEmpty, "cancel scroll leaves no mouse button held")

    gesture = TouchGestures()
    _ = gesture.update([first], at: 0)
    _ = gesture.update([first], at: 0.13)
    check(gesture.cancel() == [.up(p)], "disconnect or shutdown releases held mouse button")
    check(gesture.cancel().isEmpty, "cancel is idempotent")

    gesture = TouchGestures()
    _ = gesture.update([first, second], at: 0)
    check(gesture.update([first, contact(3, 900, 1600)], at: 0.1).isEmpty, "contact replacement cannot jump scroll")
    check(gesture.update([first], at: 0.2).isEmpty, "replaced pair stays suppressed until lift")

    gesture = TouchGestures()
    _ = gesture.update([first, second, contact(3, 700, 1400)], at: 0)
    check(gesture.update([first], at: 0.2).isEmpty, "three-finger gesture cannot become accidental click")
    check(gesture.update([], at: 0.3).isEmpty, "three-finger gesture ends without clicks")

    // Existing saved calibration and multi-display mapping remain applicable.
    let mapper = CoordinateMapper(calibration: CalibrationData(xMin: 0, xMax: 12266, yMin: 0, yMax: 6959),
        displayBounds: CGRect(x: 0, y: 1080, width: 1920, height: 1080), invertX: false, invertY: false)
    check(mapper.map(rawX: 6133, rawY: 3479.5) == CGPoint(x: 960, y: 1620), "saved calibration maps M14t center")
    check(mapper.map(rawX: 0, rawY: 0) == CGPoint(x: 0, y: 1080), "saved calibration maps top-left")
    if case .run(let config) = ArgumentParser.parse(["--two-finger-scroll", "--display", "1"]) {
        check(config.twoFingerScroll && config.displayIndex == 1, "CLI enables scrolling on selected display")
    } else { check(false, "CLI parses scroll option") }
    if case .run(let config) = ArgumentParser.parse([]) {
        check(!config.twoFingerScroll, "legacy single-touch mode remains default")
    } else { check(false, "CLI parses default mode") }

    gesture = TouchGestures()
    _ = gesture.update([first, second], at: 0)
    check(gesture.update([first, second], at: 0.02).isEmpty, "stationary pair emits no scroll")
    check(gesture.update([contact(1, 280, 1360), contact(2, 480, 1360)], at: 0.04)
          == [.scroll(at: center, dx: -20, dy: -40)], "reverse scroll preserves direction and magnitude")
    check(gesture.update([], at: 0.05).isEmpty, "two-finger lift emits no click")

    gesture = TouchGestures()
    _ = gesture.update([first], at: 0)
    _ = gesture.update([first], at: 0.13)
    check(gesture.update([first, second, contact(3, 700, 1400)], at: 0.14) == [.up(p)], "third finger safely releases active drag")

    // Reproduce the driver's rejected-report recovery while a gesture is active.
    gesture = TouchGestures()
    _ = gesture.update([first, second], at: 0)
    _ = gesture.interrupt()
    check(gesture.update([first], at: 0.05).isEmpty, "rejected scroll frame suppresses remaining finger")
    check(gesture.update([], at: 0.06).isEmpty, "lifting after rejected frame must not click")
    _ = gesture.update([first], at: 0.1)
    check(gesture.update([], at: 0.15) == [.down(p), .up(p)], "tap recovers after rejected frame and complete lift")

    gesture = TouchGestures()
    _ = gesture.update([first], at: 0)
    _ = gesture.update([first], at: 0.13)
    check(gesture.interrupt() == [.up(p)], "rejected frame releases active drag")
    check(gesture.update([first], at: 0.14).isEmpty, "rejected drag frame suppresses remaining finger")
    check(gesture.update([], at: 0.15).isEmpty, "rejected drag frame cannot produce a release click")
}
