/// Just enough protobuf (proto3 wire format) to talk to the G2. Fields must be
/// written in ascending field-number order to match the official encoder byte-for-byte.
public struct ProtoWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    private mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    private mutating func key(_ field: Int, _ wireType: UInt8) {
        varint(UInt64(field) << 3 | UInt64(wireType))
    }

    /// Singular uint32 / enum. proto3 omits zero values.
    public mutating func uint(_ field: Int, _ value: UInt32) {
        guard value != 0 else { return }
        key(field, 0)
        varint(UInt64(value))
    }

    /// Singular string. proto3 omits empty strings.
    public mutating func string(_ field: Int, _ value: String) {
        guard !value.isEmpty else { return }
        lengthDelimited(field, Array(value.utf8))
    }

    /// One element of a repeated string (always written, even if empty).
    public mutating func repeatedStringElement(_ field: Int, _ value: String) {
        lengthDelimited(field, Array(value.utf8))
    }

    /// Embedded message. Always written when called (an empty sub-message is meaningful).
    public mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        lengthDelimited(field, inner.bytes)
    }

    private mutating func lengthDelimited(_ field: Int, _ payload: [UInt8]) {
        key(field, 2)
        varint(UInt64(payload.count))
        bytes.append(contentsOf: payload)
    }
}

public struct ProtoField: Equatable {
    public let number: Int
    /// Set for wire type 0 (varint).
    public let varint: UInt64?
    /// Set for wire type 2 (length-delimited).
    public let bytes: [UInt8]?
}

public enum ProtoReader {
    /// Parses the top-level fields of a message. Returns nil on malformed input.
    /// Fixed32/fixed64 fields are skipped.
    public static func fields(_ data: [UInt8]) -> [ProtoField]? {
        var out: [ProtoField] = []
        var i = 0
        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < data.count, shift < 64 {
                let b = data[i]
                i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while i < data.count {
            guard let key = readVarint() else { return nil }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = readVarint() else { return nil }
                out.append(ProtoField(number: number, varint: v, bytes: nil))
            case 1:
                guard i + 8 <= data.count else { return nil }
                i += 8
            case 2:
                guard let len = readVarint(), len <= UInt64(data.count - i) else { return nil }
                let end = i + Int(len)
                out.append(ProtoField(number: number, varint: nil, bytes: Array(data[i..<end])))
                i = end
            case 5:
                guard i + 4 <= data.count else { return nil }
                i += 4
            default:
                return nil
            }
        }
        return out
    }

    public static func firstVarint(_ fields: [ProtoField], _ number: Int) -> UInt64? {
        fields.first { $0.number == number && $0.varint != nil }?.varint
    }

    public static func firstBytes(_ fields: [ProtoField], _ number: Int) -> [UInt8]? {
        fields.first { $0.number == number && $0.bytes != nil }?.bytes
    }
}
