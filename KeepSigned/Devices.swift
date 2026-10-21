import Foundation

struct Device: Identifiable, Hashable {
    var id: String { udid }
    var udid: String
    var name: String
    var model: String
    var link: Link = .offline
    var isPhone = false

    /// connected: tunnel up now. nearby: seen on cable/network, tunnel opens on demand. offline: not seen.
    enum Link: Int, Comparable {
        case connected, nearby, offline
        static func < (a: Link, b: Link) -> Bool { a.rawValue < b.rawValue }
        var label: String {
            switch self {
            case .connected: return "已連線"
            case .nearby: return "附近"
            case .offline: return "離線"
            }
        }
    }
}

enum Devices {
    /// Physical iOS/iPadOS devices paired with this Mac.
    static func list() async throws -> [Device] {
        let json = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepsigned-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: json) }
        let r = try await CommandRunner.run("/usr/bin/xcrun",
            ["devicectl", "list", "devices", "--json-output", json.path], timeout: 60)
        guard r.status == 0 else { throw RunnerError.message("無法列出裝置") }
        return try parse(Data(contentsOf: json))
    }

    static func parse(_ data: Data) throws -> [Device] {
        struct Root: Decodable { var result: Result }
        struct Result: Decodable { var devices: [D] }
        struct D: Decodable {
            var hardwareProperties: HW
            var deviceProperties: DP
            var connectionProperties: CP?
        }
        struct CP: Decodable { var tunnelState: String?; var pairingState: String? }
        struct HW: Decodable {
            var udid: String?
            var platform: String?
            var reality: String?
            var marketingName: String?
            var productType: String?
            var deviceType: String?
        }
        struct DP: Decodable { var name: String? }

        let devices = try JSONDecoder().decode(Root.self, from: data).result.devices.compactMap { d -> Device? in
            let hw = d.hardwareProperties
            guard hw.reality != "simulated",
                  let udid = hw.udid, Validator.matches(udid, #"^[A-Za-z0-9][A-Za-z0-9\-]{7,63}$"#),
                  ["iOS", "iPadOS"].contains(hw.platform ?? "") else { return nil }
            return Device(udid: udid,
                          name: d.deviceProperties.name ?? udid,
                          model: hw.marketingName ?? hw.productType ?? "",
                          link: link(tunnelState: d.connectionProperties?.tunnelState),
                          isPhone: hw.deviceType == "iPhone")
        }
        // Best-connected first, iPhone before iPad, so the wizard doesn't default to an offline device.
        return devices.enumerated()
            .sorted { a, b in
                let ka = (a.element.link.rawValue, a.element.isPhone ? 0 : 1, a.offset)
                let kb = (b.element.link.rawValue, b.element.isPhone ? 0 : 1, b.offset)
                return ka < kb
            }
            .map(\.element)
    }

    static func link(tunnelState: String?) -> Device.Link {
        switch tunnelState {
        case "connected": return .connected
        case "unavailable", nil: return .offline
        default: return .nearby  // "disconnected" = known and nearby, tunnel not open yet
        }
    }
}
