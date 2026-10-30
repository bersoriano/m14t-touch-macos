import CoreGraphics
import AppKit
#if SWIFT_PACKAGE
@testable import M14tTouch
#endif

/// Shared scenarios for XCTest and the Command Line Tools-only runner.
func runGestureReplayChecks(_ check: (Bool, String) -> Void) {
    runPenChecks(check)
    runPinchChecks(check)
    if case .run = ArgumentParser.parse(["--pinch-zoom"]) {
        check(true, "CLI accepts pinch zoom mode")
    } else { check(false, "CLI accepts pinch zoom mode") }
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

    // Display indices change when another screen becomes main. Identity must not.
    let touchUUID = "11111111-1111-4111-8111-111111111111"
    let otherUUID = "22222222-2222-4222-8222-222222222222"
    let oldTouch = DisplayInfo(index: 1, id: 3, uuid: touchUUID,
        bounds: CGRect(x: 2560, y: 0, width: 1920, height: 1080), isMain: false)
    let other = DisplayInfo(index: 0, id: 2, uuid: otherUUID,
        bounds: CGRect(x: 0, y: 0, width: 2560, height: 1080), isMain: true)
    var target = DisplayTarget(index: 1, uuid: nil, displays: [other, oldTouch])
    check(target.uuid == touchUUID && target.current == oldTouch, "index selection pins display identity")
    let movedDisplay = DisplayInfo(index: 0, id: 3, uuid: touchUUID,
        bounds: CGRect(x: -1600, y: -900, width: 1600, height: 900), isMain: true)
    check(target.refresh([movedDisplay, other]), "move, resize and main-display change refresh target")
    check(target.current == movedDisplay, "reordered displays retain touch screen")
    var movedMapper = mapper
    movedMapper.displayBounds = target.current!.bounds
    check(movedMapper.map(rawX: 6133, rawY: 3479.5) == CGPoint(x: -800, y: -450), "new coordinates include negative origin and new size")
    check(!target.refresh([movedDisplay, other]), "unchanged layout does not interrupt gestures")
    check(target.refresh([other]) && target.current == nil, "missing target pauses without main-display fallback")
    let returned = DisplayInfo(index: 1, id: 99, uuid: touchUUID, bounds: oldTouch.bounds, isMain: false)
    check(target.refresh([other, returned]) && target.current == returned, "reconnect follows UUID despite changed display ID")
    var absent = DisplayTarget(index: 1, uuid: touchUUID, displays: [other])
    check(absent.current == nil && absent.refresh([returned]), "saved UUID can wait for monitor at login")
    check(DisplayTarget(index: 9, uuid: nil, displays: [other]).uuid == nil, "invalid index never falls back to another screen")
    let panelID = DisplayHardwareID(vendor: 12462, model: 25251, serial: 123456)!
    var physicalTouch = oldTouch
    physicalTouch.hardwareID = panelID
    var physicalTarget = DisplayTarget(index: 1, uuid: touchUUID, displays: [other, physicalTouch])
    _ = physicalTarget.refresh([other])
    let newUUID = "33333333-3333-4333-8333-333333333333"
    let reidentified = DisplayInfo(index: 0, id: 101, uuid: newUUID,
        bounds: CGRect(x: 0, y: 1080, width: 1920, height: 1080), isMain: false,
        hardwareID: panelID)
    check(physicalTarget.refresh([other, reidentified]) && physicalTarget.current == reidentified,
          "USB reconnect recovers same physical panel with new UUID")
    check(!physicalTarget.refresh([other, reidentified]), "recovered identity remains stable")
    let siblingID = DisplayHardwareID(vendor: 12462, model: 25251, serial: 654321)!
    let sibling = DisplayInfo(index: 1, id: 102, uuid: touchUUID,
        bounds: oldTouch.bounds, isMain: true, hardwareID: siblingID)
    _ = physicalTarget.refresh([other, sibling])
    check(physicalTarget.current == nil, "same model with different serial cannot take over old UUID")
    _ = physicalTarget.refresh([sibling, reidentified])
    check(physicalTarget.current == reidentified, "physical identity wins over reused UUID on another panel")
    let duplicate = DisplayInfo(index: 2, id: 103, uuid: "44444444-4444-4444-8444-444444444444",
        bounds: other.bounds, isMain: false, hardwareID: panelID)
    _ = physicalTarget.refresh([reidentified, duplicate])
    check(physicalTarget.current == nil, "ambiguous hardware identity pauses instead of guessing")
    var savedPhysical = DisplayTarget(index: 0, uuid: touchUUID, hardwareID: panelID, displays: [other])
    check(savedPhysical.current == nil && savedPhysical.refresh([other, reidentified]) &&
          savedPhysical.current == reidentified, "saved hardware identity recovers after login while disconnected")
    check(DisplayTarget(index: 0, uuid: touchUUID, hardwareID: panelID,
        displays: [other, reidentified]).current == reidentified, "saved hardware identity recovers stale UUID at startup")
    var lateArrival = DisplayTarget(index: 1, uuid: touchUUID, displays: [other])
    _ = lateArrival.refresh([other, physicalTouch])
    _ = lateArrival.refresh([other])
    _ = lateArrival.refresh([other, reidentified])
    check(lateArrival.current == reidentified,
          "UUID-only launch learns physical identity when absent panel first connects")
    check(DisplayTarget(index: 0, uuid: nil, hardwareID: panelID,
        displays: [other, reidentified]).current == reidentified, "hardware selector overrides default display index")
    check(DisplayTarget(index: 0, uuid: nil, hardwareID: panelID,
        displays: [reidentified, duplicate]).current == nil, "hardware-only selection rejects duplicate serials")
    var noSerial = DisplayTarget(index: 1, uuid: touchUUID, displays: [other, oldTouch])
    _ = noSerial.refresh([other, reidentified])
    check(noSerial.current == nil, "missing serial never guesses by model or resolution")
    check(DisplayHardwareID(vendor: 12462, model: 25251, serial: 0) == nil,
          "zero serial disables physical fallback")
    if case .run(let config) = ArgumentParser.parse(["--display-hardware-id", panelID.description]) {
        check(config.displayHardwareID == panelID, "CLI accepts persistent physical identity")
    } else { check(false, "CLI accepts persistent physical identity") }
    for invalid in ["", "1:2", "1:2:0", "1::3", "1:2:-3", "1:2:4294967296", "1:2:3:4", "x:2:3"] {
        if case .error = ArgumentParser.parse(["--display-hardware-id", invalid]) {
            check(true, "CLI rejects invalid hardware ID \(invalid)")
        } else { check(false, "CLI rejects invalid hardware ID \(invalid)") }
    }
    if case .printDisplayHardwareID(let config) = ArgumentParser.parse(["--print-display-hardware-id", "--display", "1"]) {
        check(config.displayIndex == 1, "installer can query selected physical identity")
    } else { check(false, "installer can query selected physical identity") }
    if case .error = ArgumentParser.parse(["--print-display-uuid", "--print-display-hardware-id"]) {
        check(true, "installer print actions cannot be mixed")
    } else { check(false, "installer print actions cannot be mixed") }
    if case .run(let config) = ArgumentParser.parse(["--display-uuid", touchUUID.lowercased()]) {
        check(config.displayUUID == touchUUID, "CLI normalizes stable display UUID")
    } else { check(false, "CLI accepts display UUID") }
    if case .error = ArgumentParser.parse(["--display-uuid", "bad"]) {
        check(true, "CLI rejects malformed display UUID")
    } else { check(false, "CLI rejects malformed display UUID") }
    if case .printDisplayUUID(let config) = ArgumentParser.parse(["--print-display-uuid", "--display", "0"]) {
        check(config.displayIndex == 0, "UUID lookup accepts later display option")
    } else { check(false, "CLI supports installer UUID lookup") }

    gesture = TouchGestures()
    _ = gesture.update([first], at: 0)
    check(gesture.interrupt().isEmpty && !gesture.isPending, "layout change cancels delayed press")
    check(gesture.update([first], at: 1).isEmpty, "timer cannot click stale coordinates after layout change")
    _ = gesture.update([], at: 1.1)
    _ = gesture.update([first, second], at: 2)
    _ = gesture.interrupt()
    check(gesture.update([first, second], at: 2.1).isEmpty, "layout change discards old scroll anchor")
    _ = gesture.update([], at: 2.2)
    let newFirst = contact(1, -900, -450)
    let newSecond = contact(2, -700, -450)
    check(gesture.update([newFirst, newSecond], at: 3) == [.move(CGPoint(x: -800, y: -450))], "new scroll anchors on moved touch display")

    // USB can continue reporting a release while the video connection is absent.
    gesture = TouchGestures()
    _ = gesture.update([first], at: 0)
    _ = gesture.update([first], at: 0.13)
    check(gesture.update([first], at: 0.2, inputEnabled: false) == [.up(p)], "missing display releases active drag")
    check(gesture.update([first, second], at: 0.3, inputEnabled: false).isEmpty, "missing display cannot start scroll")
    check(gesture.update([], at: 0.4, inputEnabled: false).isEmpty, "release while missing emits no click")
    check(gesture.update([newFirst], at: 0.5) == [.move(newFirst.point)], "first touch after reconnect works when fingers lifted while missing")
    check(gesture.update([], at: 0.55) == [.down(newFirst.point), .up(newFirst.point)], "reconnected tap lands in new coordinate space")
    _ = gesture.update([first, second], at: 1, inputEnabled: false)
    check(gesture.update([first, second], at: 1.1).isEmpty, "fingers held through reconnect remain suppressed until lift")

}

func runPenChecks(_ check: (Bool, String) -> Void) {
    func packet(_ flags: UInt8 = 0x20, id: UInt8 = 6, x: UInt16 = 15465, y: UInt16 = 8700, pressure: UInt16 = 2048) -> [UInt8] {
        // Both input reports are 18 bytes. Report 0x0B's 63-byte feature
        // payload is a different report type, not appended pen input.
        var bytes = [UInt8](repeating: 0, count: 18)
        bytes[0] = id; bytes[1] = flags
        for (offset, value) in [(2,x), (4,y), (6,pressure)] { bytes[offset] = UInt8(value & 255); bytes[offset+1] = UInt8(value >> 8) }
        bytes[16] = UInt8(bitPattern: -45); bytes[17] = 90
        return bytes
    }
    let hover = PenReport.decode(packet())!
    let down = PenReport.decode(packet(0x21))!
    let gone = PenReport.decode(packet(0))!
    let right = PenReport.decode(packet(0x22))!
    let eraser = PenReport.decode(packet(0x34))!
    check(hover.inRange && !hover.touching, "pen hover decoded separately from tip contact")
    check(down.touching && down.pressure == 2048.0/4095, "pen pressure retains hardware precision")
    check(hover.tilt == CGPoint(x: -0.5, y: 1), "pen signed tilt decoded")
    check(eraser.touching && eraser.eraser, "eraser contact works without tip-switch bit")
    check(right.barrel, "lower pen button decoded")
    check(PenReport.decode(packet(0x21, id: 11)) == down, "vendor pen report uses same layout")
    check(PenReport.decode(packet(0x21, id: 11) + [UInt8](repeating: 0, count: 63)) == nil, "feature payload is not part of pen input")
    // Captured in Windows mode after USB reconnect; pen serial fields removed.
    let capturedTip: [UInt8] = [0x06, 0x21, 0x4d, 0x4a, 0xc3, 0x2f, 0x60, 0x05,
                                0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    let captured = PenReport.decode(capturedTip)
    check(captured?.touching == true && captured?.inRange == true &&
          captured?.rawPoint == CGPoint(x: 19021, y: 12227) &&
          captured?.pressure == 1376.0/4095, "captured Windows-mode tip report decodes position and pressure")
    check(PenReport.decode(Array(packet().prefix(17))) == nil, "truncated pen packet rejected")
    check(PenReport.decode(packet(id: 12)) == nil, "finger report cannot become pen event")
    check(PenReport.decode(packet(x: 30932)) == nil, "out-of-range pen coordinate rejected")
    check(PenReport.decode(packet(0x21, pressure: 4096)) == nil, "invalid pressure rejected")
    let exitWithButton = PenReport.decode(packet(0x02, x: 65535, y: 65535, pressure: 65535))
    check(exitWithButton != nil && !exitWithButton!.inRange, "range exit tolerates stale button and coordinate fields")
    var fingers = TouchGestures()
    check(fingers.interruptForPen().isEmpty, "pen hover leaves idle fingers ready")
    let finger = TouchContact(id: 1, point: CGPoint(x: 100, y: 100))
    _ = fingers.update([finger], at: 0)
    check(fingers.update([], at: 0.05) == [.down(finger.point), .up(finger.point)], "first finger tap after idle pen handoff works")
    _ = fingers.update([finger], at: 1)
    check(fingers.interruptForPen().isEmpty, "pen cancels delayed finger click")
    check(fingers.update([], at: 1.05).isEmpty, "finger lift after pen takeover cannot click")
    _ = fingers.update([finger], at: 2)
    _ = fingers.update([finger], at: 2.13)
    check(fingers.interruptForPen() == [.up(finger.point)], "pen takeover releases active finger drag")
    let bounds = CGRect(x: -1600, y: 900, width: 1600, height: 900)
    let corner = PenReport.decode(packet(x: 30931, y: 17399))!
    check(corner.point(in: bounds, invertX: false, invertY: false) == CGPoint(x: -1, y: 1799), "pen edge stays inside target display")
    check(corner.point(in: bounds, invertX: true, invertY: true) == bounds.origin, "pen inversion preserves target origin")

    let p = CGPoint(x: -800, y: 1300)
    var pen = PenInput()
    let entering = pen.update(hover, at: p)
    check(entering.first == .proximity(p, entering: true, eraser: false), "hover enters tablet proximity")
    check(entering.last?.eventType == .mouseMoved, "hover moves pointer without clicking")
    check(pen.update(down, at: p).map(\.eventType) == [.leftMouseDown], "pen tip clicks immediately")
    check(pen.update(down, at: p).map(\.eventType) == [.leftMouseDragged], "pen contact sends drawing samples")
    check(pen.update(hover, at: p).first?.eventType == .leftMouseUp, "tip lift releases pen button")
    check(pen.update(right, at: p).last?.eventType == .rightMouseDown, "barrel starts right click")
    check(pen.update(gone, at: .zero).first?.eventType == .rightMouseUp, "pen leaving range releases at last valid point")
    check(!pen.isInRange, "out-of-range clears pen proximity")
    _ = pen.update(down, at: p)
    check(pen.interrupt().first?.eventType == .leftMouseUp, "layout change or malformed packet releases pen")
    check(pen.update(down, at: p).isEmpty, "interrupted pen stroke cannot resume until lift")
    _ = pen.update(hover, at: p)
    check(pen.update(down, at: p).last?.eventType == .leftMouseDown, "pen resumes after hover lift")
    _ = pen.update(gone, at: p, inputEnabled: false)
    check(pen.update(down, at: p).last?.eventType == .leftMouseDown, "release while display absent permits next pen stroke")
    check(pen.cancel().first?.eventType == .leftMouseUp && pen.cancel().isEmpty, "disconnect safely releases pen once")
    let eraseEvents = pen.update(eraser, at: p)
    check(eraseEvents.first == .proximity(p, entering: true, eraser: true), "top button advertises eraser proximity")
    let event = MouseEmitter().makePenEvent(eraseEvents.last!)!
    check(abs(event.getDoubleValueField(.tabletEventPointPressure) - eraser.pressure) < 1.0/65535, "tablet event carries pressure")
    check(abs(event.getDoubleValueField(.tabletEventTiltX) + 0.5) < 1.0/32767, "tablet event carries tilt")
    check(event.getIntegerValueField(.mouseEventSubtype) == 1, "pen events marked as tablet points")
    for (type, button, mask): (CGEventType, CGMouseButton, Int64) in [
        (.leftMouseDown, .left, 1), (.leftMouseDragged, .left, 1),
        (.rightMouseDown, .right, 2), (.rightMouseDragged, .right, 2),
        (.leftMouseUp, .left, 0), (.rightMouseUp, .right, 0), (.mouseMoved, .left, 0)
    ] {
        let sample = MouseEmitter().makePenEvent(.pointer(type: type, button: button,
            point: p, pressure: mask == 1 ? 0.5 : 0, tilt: .zero))!
        check(sample.getIntegerValueField(.tabletEventPointButtons) == mask,
              "tablet button mask matches mouse event \(type.rawValue)")
    }
    for (args, enabled): ([String], Bool) in [
        ([], true), (["--no-stylus"], false),
        (["--stylus", "--no-stylus"], false),
        (["--no-stylus", "--stylus"], true)
    ] {
        if case .run(let config) = ArgumentParser.parse(args) {
            check(config.stylus == enabled, "pen defaults and overrides: \(args)")
        } else { check(false, "pen options parse: \(args)") }
    }
    if case .run(let config) = ArgumentParser.parse(["--stylus", "--two-finger-scroll"]) {
        check(config.stylus && config.twoFingerScroll, "pen and scrolling can run together")
    } else { check(false, "CLI accepts stylus mode") }
}

/// Replay pinch recognition and inspect AppKit's interpretation without posting events.
func runPinchChecks(_ check: (Bool, String) -> Void) {
    let anchor = CGPoint(x: 400, y: 1400)
    func pair(_ left: Double = 300, _ right: Double = 500, y: Double = 1400) -> [TouchContact] {
        [TouchContact(id: 1, point: CGPoint(x: left, y: y)),
         TouchContact(id: 2, point: CGPoint(x: right, y: y))]
    }
    func isZoom(_ actions: [TouchAction], _ delta: Double, _ phase: MagnifyPhase) -> Bool {
        guard actions.count == 1, case .magnify(let point, let value, let actualPhase) = actions[0] else { return false }
        return point == anchor && abs(value - delta) < 0.000001 && actualPhase == phase
    }
    var gesture = TouchGestures(pinchZoom: true)
    check(gesture.update(pair(), at: 0) == [.move(anchor)], "pinch candidate positions cursor without clicking")
    check(gesture.update(pair(299, 501), at: 0.01).isEmpty, "small span jitter does not trigger zoom or scroll")
    let spread = gesture.update(pair(280, 520).reversed(), at: 0.02)
    check(spread.count == 2 && isZoom(Array(spread.prefix(1)), 0, .began) &&
          isZoom(Array(spread.suffix(1)), 0.2, .changed), "spread begins native zoom with positive delta despite reordered slots")
    check(isZoom(gesture.update(pair(300, 500), at: 0.03), -1.0/6.0, .changed),
          "closing fingers reverses zoom within same pinch")
    check(gesture.update(pair(320, 520, y: 1420), at: 0.04).isEmpty,
          "moving pinching pair together does not also scroll")
    check(isZoom(gesture.update([pair()[0]], at: 0.05), 0, .ended), "lifting first finger ends pinch once")
    check(gesture.update(pair(), at: 0.06).isEmpty, "replacement finger cannot restart pinch before complete lift")
    check(gesture.update([], at: 0.07).isEmpty, "pinch release emits no click or second end")
    _ = gesture.update([pair()[0]], at: 0.1)
    check(gesture.update([], at: 0.15) == [.down(CGPoint(x: 300, y: 1400)), .up(CGPoint(x: 300, y: 1400))],
          "single tap recovers after pinch")

    gesture = TouchGestures(pinchZoom: true)
    _ = gesture.update(pair(), at: 0)
    let close = gesture.update(pair(320, 480), at: 0.01)
    check(close.count == 2 && isZoom(Array(close.suffix(1)), -0.2, .changed), "pinch closed starts zoom out")
    check(isZoom(gesture.update([], at: 0.02), 0, .ended), "simultaneous lift ends pinch")

    gesture = TouchGestures(pinchZoom: true)
    _ = gesture.update(pair(0, 800), at: 0)
    check(gesture.update(pair(0, 814), at: 0.01).isEmpty,
          "wide asymmetric pinch waits for zoom threshold instead of locking to scroll")
    let asymmetric = gesture.update(pair(0, 840), at: 0.02)
    check(asymmetric.count == 2 && isZoom(Array(asymmetric.suffix(1)), 0.05, .changed),
          "one stationary finger can anchor a wide pinch")

    gesture = TouchGestures(pinchZoom: true)
    _ = gesture.update(pair(), at: 0)
    check(gesture.update(pair(315, 515, y: 1430), at: 0.01) == [.scroll(at: anchor, dx: 15, dy: 30)],
          "parallel motion preserves both scroll axes")
    check(gesture.update(pair(280, 550, y: 1450), at: 0.02) == [.scroll(at: anchor, dx: 0, dy: 20)],
          "established scroll cannot turn into accidental zoom")

    for reason in ["disconnect", "bad report", "display change", "pen proximity", "third finger", "contact replacement"] {
        gesture = TouchGestures(pinchZoom: true)
        _ = gesture.update(pair(), at: 0)
        _ = gesture.update(pair(280, 520), at: 0.01)
        let actions: [TouchAction]
        switch reason {
        case "disconnect": actions = gesture.cancel()
        case "bad report", "display change": actions = gesture.interrupt()
        case "pen proximity": actions = gesture.interruptForPen()
        case "third finger": actions = gesture.update(pair() + [TouchContact(id: 3, point: .zero)], at: 0.02)
        default: actions = gesture.update([pair()[0], TouchContact(id: 3, point: pair()[1].point)], at: 0.02)
        }
        check(isZoom(actions, 0, .cancelled), "\(reason) cancels active pinch at original screen anchor")
        check(gesture.cancel().isEmpty, "\(reason) sends no duplicate pinch termination")
    }

    gesture = TouchGestures(pinchZoom: true)
    _ = gesture.update(pair(400, 400), at: 0)
    check(gesture.update(pair(300, 500), at: 0.01).isEmpty,
          "coincident initial contacts cannot cause division by zero or sudden zoom")
    gesture = TouchGestures(pinchZoom: true)
    _ = gesture.update(pair(), at: 0)
    _ = gesture.update(pair(280, 520), at: 0.01)
    check(isZoom(gesture.update(pair(400, 400), at: 0.02), 0, .cancelled),
          "collapsing contacts safely cancels pinch")

    if case .run(let config) = ArgumentParser.parse(["--pinch-zoom", "--stylus"]) {
        check(config.pinchZoom && config.twoFingerScroll && config.stylus, "pinch mode enables report path and coexists with stylus")
    } else { check(false, "pinch CLI parses with stylus") }
    if case .run(let config) = ArgumentParser.parse(["--two-finger-scroll"]) {
        check(!config.pinchZoom, "scroll-only opt-in keeps previous behavior")
    }

    let emitter = MouseEmitter()
    let phases: [(MagnifyPhase, NSEvent.Phase, Double)] = [(.began, .began, 0), (.changed, .changed, 0.2),
        (.changed, .changed, -0.2), (.ended, .ended, 0), (.cancelled, .cancelled, 0)]
    for (phase, expected, delta) in phases {
        guard let cg = emitter.makeMagnifyEvent(at: anchor, delta: delta, phase: phase),
              let ns = NSEvent(cgEvent: cg) else { check(false, "native magnify event decodes in AppKit"); continue }
        check(ns.type == .magnify && ns.phase == expected && abs(ns.magnification - delta) < 0.00001 && cg.location == anchor,
              "AppKit receives magnify \(phase) with correct sign and M14t location")
        check(cg.flags.isEmpty, "pinch does not inject keyboard modifiers or system-wide zoom shortcuts")
    }
    check(emitter.makeMagnifyEvent(at: anchor, delta: .nan, phase: .changed) == nil,
          "nonfinite magnification cannot reach event system")
}
