import CoreGraphics
import ColorSync

/// EDID identity survives connection changes that can replace macOS's UUID.
/// A missing serial cannot safely identify one physical panel.
struct DisplayHardwareID: Equatable, CustomStringConvertible {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    init?(vendor: UInt32, model: UInt32, serial: UInt32) {
        guard vendor != 0, model != 0, serial != 0 else { return nil }
        self.vendor = vendor; self.model = model; self.serial = serial
    }

    init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let vendor = UInt32(parts[0]),
              let model = UInt32(parts[1]), let serial = UInt32(parts[2]) else { return nil }
        self.init(vendor: vendor, model: model, serial: serial)
    }

    var description: String { "\(vendor):\(model):\(serial)" }
}

/// A connected display, including optional physical hardware identity.
struct DisplayInfo: Equatable {
    let index: Int
    let id: CGDirectDisplayID
    let uuid: String
    let bounds: CGRect
    let isMain: Bool
    var hardwareID: DisplayHardwareID? = nil
}

/// Pins the initial selection to one physical display. Never falls back to main.
struct DisplayTarget {
    let uuid: String?
    private(set) var hardwareID: DisplayHardwareID?
    private(set) var current: DisplayInfo?

    init(index: Int, uuid: String?, hardwareID: DisplayHardwareID? = nil, displays: [DisplayInfo]) {
        let selectedUUID = uuid ?? (hardwareID == nil ? displays.first(where: { $0.index == index })?.uuid : nil)
        self.uuid = selectedUUID
        self.hardwareID = hardwareID ?? displays.first(where: { $0.uuid == selectedUUID })?.hardwareID
        current = nil
        current = resolve(displays)
    }

    /// Returns true when mapping or availability changed.
    mutating func refresh(_ displays: [DisplayInfo]) -> Bool {
        let next = resolve(displays)
        // A UUID-only agent can start before the panel connects. Learn its
        // physical identity on that first successful match for later reconnects.
        if hardwareID == nil { hardwareID = next?.hardwareID }
        guard next != current else { return false }
        current = next
        return true
    }

    private func resolve(_ displays: [DisplayInfo]) -> DisplayInfo? {
        if let exact = displays.first(where: { $0.uuid == uuid }),
           hardwareID == nil || exact.hardwareID == hardwareID { return exact }
        guard let hardwareID else { return nil }
        let matches = displays.filter { $0.hardwareID == hardwareID }
        return matches.count == 1 ? matches[0] : nil
    }
}

enum DisplayResolver {
    private static let maxDisplays = 16

    static func all() -> [DisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: maxDisplays)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(maxDisplays), &ids, &count) == .success else { return [] }
        return (0..<Int(count)).compactMap { i in
            guard let value = CGDisplayCreateUUIDFromDisplayID(ids[i]) else { return nil }
            let uuid = CFUUIDCreateString(nil, value.takeRetainedValue()) as String
            return DisplayInfo(index: i, id: ids[i], uuid: uuid,
                bounds: CGDisplayBounds(ids[i]), isMain: CGDisplayIsMain(ids[i]) != 0,
                hardwareID: DisplayHardwareID(vendor: CGDisplayVendorNumber(ids[i]),
                    model: CGDisplayModelNumber(ids[i]), serial: CGDisplaySerialNumber(ids[i])))
        }
    }
}
