import CoreGraphics

/// Gen 1 pen layout from upstream HIDReportParser, checked against the connected
/// 2d1f:524c descriptor. Pen coordinates are independent of finger calibration.
struct PenReport: Equatable {
    let inRange: Bool
    let touching: Bool
    let barrel: Bool
    let eraser: Bool
    let rawPoint: CGPoint
    let pressure: Double
    let tilt: CGPoint

    static func decode(_ bytes: [UInt8]) -> PenReport? {
        // Input and feature reports have independent lengths, even when they
        // share an ID. Both pen input reports contain 17 bytes after the ID.
        guard let id = bytes.first, (id == 6 || id == 11), bytes.count == 18 else { return nil }
        func word(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset+1]) << 8 }
        let x = word(2), y = word(4), pressure = word(6)
        let flags = bytes[1]
        let inRange = flags & 0x20 != 0
        // Firmware can retain stale coordinates/buttons when leaving range.
        // Always deliver that exit so held buttons and palm suppression release.
        guard !inRange || (x <= 30931 && y <= 17399 && pressure <= 4095) else { return nil }
        let touching = flags & 0x05 != 0 // Tip or eraser contact.
        return PenReport(inRange: inRange,
            touching: touching, barrel: flags & 0x02 != 0, eraser: flags & 0x1c != 0,
            rawPoint: CGPoint(x: x, y: y), pressure: touching ? Double(pressure)/4095 : 0,
            tilt: CGPoint(x: min(1, max(-1, Double(Int8(bitPattern: bytes[16]))/90)),
                          y: min(1, max(-1, Double(Int8(bitPattern: bytes[17]))/90))))
    }

    func point(in bounds: CGRect, invertX: Bool, invertY: Bool) -> CGPoint {
        let x = invertX ? 1 - rawPoint.x/30931 : rawPoint.x/30931
        let y = invertY ? 1 - rawPoint.y/17399 : rawPoint.y/17399
        // The maximum edge is outside a display's pixel area.
        return CGPoint(x: bounds.minX + min(x * bounds.width, max(0, bounds.width - 1)),
                       y: bounds.minY + min(y * bounds.height, max(0, bounds.height - 1)))
    }
}
