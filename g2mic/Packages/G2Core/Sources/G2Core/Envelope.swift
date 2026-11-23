/// G2 BLE transport envelope (reverse-engineered by the g2-kit / even-g2-protocol projects).
///
///     aa 21 <seq> <len> <totalFrags> <fragIdx> <sid> <flag> <chunk...>     phone -> glasses
///     aa 12 <seq> <len> <totalFrags> <fragIdx> <sid> <flag> <chunk...>     glasses -> phone
///
/// `len` is the chunk length. The last fragment's chunk ends with the CRC-16/CCITT-FALSE
/// (little-endian) of the whole logical payload. Every fragment of one message shares
/// the same `seq` byte; the firmware uses it as the reassembly key.
public enum Envelope {
    public static let syncTx: [UInt8] = [0xAA, 0x21]
    public static let syncRx: [UInt8] = [0xAA, 0x12]
    public static let headerSize = 8
    public static let flagRequest: UInt8 = 0x20
    public static let defaultChunkSize = 232

    public static func frame(
        payload: [UInt8],
        seq: UInt8,
        sid: UInt8,
        flag: UInt8 = flagRequest,
        chunkSize: Int = defaultChunkSize
    ) -> [[UInt8]] {
        precondition(chunkSize > 2 && chunkSize <= 255, "chunk length must fit in one byte")
        let crc = CRC16.ccittFalse(payload)
        let body = payload + [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        let total = max(1, (body.count + chunkSize - 1) / chunkSize)
        precondition(total <= 255, "message too large")
        var frames: [[UInt8]] = []
        frames.reserveCapacity(total)
        for index in 0..<total {
            let start = index * chunkSize
            let chunk = body[start..<min(start + chunkSize, body.count)]
            var f: [UInt8] = syncTx
            f += [seq, UInt8(chunk.count), UInt8(total), UInt8(index + 1), sid, flag]
            f += chunk
            frames.append(f)
        }
        return frames
    }
}

/// One BLE notification parsed as an envelope fragment.
public struct EnvelopeFragment: Equatable {
    public let isFromGlasses: Bool
    public let seq: UInt8
    public let totalFrags: UInt8
    public let fragIndex: UInt8
    public let sid: UInt8
    public let flag: UInt8
    public let chunk: [UInt8]

    public static func parse(_ raw: [UInt8]) -> EnvelopeFragment? {
        guard raw.count >= Envelope.headerSize, raw[0] == 0xAA, raw[1] == 0x12 || raw[1] == 0x21 else {
            return nil
        }
        let len = Int(raw[3])
        let end = min(raw.count, Envelope.headerSize + len)
        return EnvelopeFragment(
            isFromGlasses: raw[1] == 0x12,
            seq: raw[2],
            totalFrags: raw[4],
            fragIndex: raw[5],
            sid: raw[6],
            flag: raw[7],
            chunk: Array(raw[Envelope.headerSize..<end])
        )
    }
}

/// A complete logical message after reassembly.
public struct EnvelopeMessage: Equatable {
    public let sid: UInt8
    public let flag: UInt8
    public let payload: [UInt8]
    public let crcValid: Bool

    /// EvenHub-style payloads carry the command in field 1 and the echoed request "magic" in field 2.
    public var fields: [ProtoField]? { ProtoReader.fields(payload) }
    public var command: UInt32? { fields.flatMap { ProtoReader.firstVarint($0, 1) }.map { UInt32(truncatingIfNeeded: $0) } }
    public var magic: UInt32? { fields.flatMap { ProtoReader.firstVarint($0, 2) }.map { UInt32(truncatingIfNeeded: $0) } }
}

/// Reassembles multi-fragment messages coming back from one arm.
public struct EnvelopeReassembler {
    private var pending: [UInt8: [UInt8]] = [:]

    public init() {}

    public mutating func push(_ raw: [UInt8]) -> EnvelopeMessage? {
        guard let frag = EnvelopeFragment.parse(raw) else { return nil }
        let total = max(1, Int(frag.totalFrags))
        let index = Int(frag.fragIndex)
        if index <= 1 { pending[frag.seq] = [] }
        pending[frag.seq, default: []] += frag.chunk
        guard index >= total else { return nil }
        let body = pending.removeValue(forKey: frag.seq) ?? frag.chunk
        guard body.count >= 2 else { return nil }
        let payload = Array(body[0..<(body.count - 2)])
        let crc = UInt16(body[body.count - 2]) | UInt16(body[body.count - 1]) << 8
        return EnvelopeMessage(
            sid: frag.sid,
            flag: frag.flag,
            payload: payload,
            crcValid: crc == CRC16.ccittFalse(payload)
        )
    }
}
