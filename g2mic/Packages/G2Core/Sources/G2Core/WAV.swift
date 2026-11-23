import Foundation

/// Builds a 16-bit PCM mono WAV file in memory.
public enum WAV {
    public static func header(sampleCount: Int, sampleRate: Int = G2AudioFormat.sampleRate) -> Data {
        let dataBytes = UInt32(sampleCount * 2)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1) // PCM
        u16(1) // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2)) // byte rate
        u16(2) // block align
        u16(16) // bits per sample
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }

    public static func file(samples: [Int16], sampleRate: Int = G2AudioFormat.sampleRate) -> Data {
        var d = header(sampleCount: samples.count, sampleRate: sampleRate)
        samples.withUnsafeBufferPointer { buf in
            for s in buf { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        }
        return d
    }
}
