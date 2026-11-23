import Foundation

/// Bluetooth identifiers and message builders for the Even Realities G2.
///
/// Sources (community reverse engineering, not affiliated with Even Realities):
///   https://github.com/Commute773/g2-kit          (verified on hardware)
///   https://github.com/i-soxi/even-g2-protocol
public enum G2UUID {
    private static func uuid(_ suffix: String) -> String { "00002760-08C2-11E1-9073-0E8AC72E\(suffix)" }
    /// Command service and its characteristics.
    public static let commandService = uuid("5450")
    public static let commandWrite = uuid("5401")
    public static let commandNotify = uuid("5402")
    /// "Render" service. Mic audio (LC3) arrives on its notify characteristic.
    public static let renderService = uuid("6450")
    public static let renderWrite = uuid("6401")
    public static let renderNotify = uuid("6402")
}

public enum G2Arm: String, Sendable {
    case left = "L"
    case right = "R"

    /// Arms advertise as e.g. `Even G2_32_L_ABC123` (model, variant number, side, serial).
    public static func from(advertisedName name: String?) -> G2Arm? {
        guard let name else { return nil }
        let parts = name.split(separator: "_").map(String.init)
        guard parts.count >= 3 else { return nil }
        for i in 1..<(parts.count - 1) {
            let model = parts[i - 1].uppercased()
            let looksLikeModel = model.range(of: #"G\d+$"#, options: .regularExpression) != nil
            let isNumber = !parts[i].isEmpty && parts[i].allSatisfy(\.isNumber)
            guard looksLikeModel, isNumber else { continue }
            switch parts[i + 1].uppercased() {
            case "L": return .left
            case "R": return .right
            default: return nil
            }
        }
        return nil
    }
}

/// sid=0x01 "app launch" prelude. Must be the first thing sent to the right arm after
/// connecting, or the glasses silently ignore EvenHub traffic. Bytes captured from the
/// official app; the reply echoes magic 156.
public enum AppLaunch {
    public static let sid: UInt8 = 0x01
    public static let preludeSeq: UInt8 = 0x92
    public static let preludeMagic: UInt32 = 156
    public static let preludePayload: [UInt8] = [
        0x08, 0x02, 0x10, 0x9C, 0x01, 0x22, 0x0A, 0x1A, 0x08, 0x12,
        0x06, 0x12, 0x04, 0x08, 0x00, 0x10, 0x00,
    ]
}

/// sid=0xE0 "EvenHub": containers on the lens, heartbeat, and mic control.
public enum EvenHub {
    public static let sid: UInt8 = 0xE0

    public enum Cmd: UInt32 {
        case createStartupPage = 0
        case createStartupPageResponse = 1
        case notifyEvent = 2
        case rebuildPage = 7
        case rebuildPageResponse = 8
        case shutdownPage = 9
        case heartbeat = 12
        case heartbeatResponse = 13
        case audioControl = 15
        case audioControlResponse = 16
    }

    // Field numbers in evenhub_main_msg_ctx.
    private enum Field {
        static let cmd = 1
        static let magic = 2
        static let createMessage = 3
        static let rebuildContainer = 7
        static let heartbeat = 14
        static let audioControl = 18
        static let audioResponse = 19
    }

    /// Firmware only compares the low byte of the magic, so keep it in 0...255.
    private static func header(_ w: inout ProtoWriter, _ cmd: Cmd, _ magic: UInt8) {
        w.uint(Field.cmd, cmd.rawValue)
        w.uint(Field.magic, UInt32(magic))
    }

    /// Turn the glasses' microphones on or off. Requires a live startup page + heartbeats.
    public static func audioControl(enable: Bool, magic: UInt8) -> [UInt8] {
        var w = ProtoWriter()
        header(&w, .audioControl, magic)
        w.message(Field.audioControl) { $0.uint(1, enable ? 1 : 0) }
        return w.bytes
    }

    /// Keeps the "plugin task" alive. The firmware tears it down (and stops the mic)
    /// after ~10 s without traffic; send every ~5 s.
    public static func heartbeat(magic: UInt8) -> [UInt8] {
        var w = ProtoWriter()
        header(&w, .heartbeat, magic)
        w.message(Field.heartbeat) { _ in }
        return w.bytes
    }

    /// A small list container. Creating one brings up the plugin task, which the mic needs.
    /// `name` must be at most 14 characters.
    public static func createStartupPage(name: String, items: [String], magic: UInt8) -> [UInt8] {
        precondition(name.count <= 14, "container names are capped at 14 characters")
        var w = ProtoWriter()
        header(&w, .createStartupPage, magic)
        w.message(Field.createMessage) { c in
            c.uint(1, 1) // ContainerTotalNum
            c.message(2) { l in // ListObject
                l.uint(3, 280) // Width
                l.uint(4, 130) // Height
                l.uint(9, 1) // ContainerID
                l.string(10, name)
                l.message(11) { item in // ItemContainer
                    item.uint(1, UInt32(items.count))
                    item.uint(3, 1) // IsItemSelectBorderEn
                    for i in items { item.repeatedStringElement(4, i) }
                }
                l.uint(12, 1) // IsEventCapture
            }
            c.uint(5, 10000) // widgetId
        }
        return w.bytes
    }

    /// Replace the page with a single text container (shows status on the lens).
    public static func rebuildWithText(name: String, text: String, magic: UInt8) -> [UInt8] {
        precondition(name.count <= 14, "container names are capped at 14 characters")
        var w = ProtoWriter()
        header(&w, .rebuildPage, magic)
        w.message(Field.rebuildContainer) { r in
            r.uint(1, 1) // ContainerTotalNum
            r.message(3) { t in // TextObject
                t.uint(3, 576) // Width
                t.uint(4, 288) // Height
                t.uint(9, 1) // ContainerID
                t.string(10, name)
                t.string(12, truncateUTF8(text, maxBytes: 900)) // firmware caps content near 1000 bytes
            }
        }
        return w.bytes
    }

    static func truncateUTF8(_ s: String, maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        var out = ""
        var used = 0
        for ch in s {
            let n = String(ch).utf8.count
            if used + n > maxBytes { break }
            out.append(ch)
            used += n
        }
        return out
    }

    /// AudioResCommand.AudioStat from a Cmd=16 reply, if present.
    public static func audioStatus(from message: EnvelopeMessage) -> UInt32? {
        guard let fields = message.fields,
              let inner = ProtoReader.firstBytes(fields, Field.audioResponse),
              let innerFields = ProtoReader.fields(inner) else { return nil }
        return ProtoReader.firstVarint(innerFields, 1).map { UInt32(truncatingIfNeeded: $0) } ?? 0
    }
}
