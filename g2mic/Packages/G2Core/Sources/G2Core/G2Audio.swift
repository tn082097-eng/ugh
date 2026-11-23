import CLC3
import Foundation

/// G2 mic stream format.
///
/// After `EvenHub.audioControl(enable: true)`, each notification on the render-notify
/// characteristic (usually from the LEFT arm) is a 205-byte packet:
///
///     bytes   0..<200  five 40-byte LC3 frames (10 ms each, 16 kHz mono, 32 kbps)
///     bytes 200..<205  trailer; byte 204 is a packet counter mod 256
///
/// One packet = 50 ms = 800 samples. Source: g2-kit `lc3-decoder.ts`, verified on hardware.
public enum G2AudioFormat {
    public static let sampleRate = 16_000
    public static let frameDurationMicros: Int32 = 10_000
    public static let frameBytes = 40
    public static let framesPerPacket = 5
    public static let samplesPerFrame = 160
    public static let samplesPerPacket = framesPerPacket * samplesPerFrame
    public static let packetBytes = 205
    public static let counterOffset = 204
}

/// Thin Swift wrapper over one liblc3 decoder instance (one mono stream).
public final class LC3Decoder {
    private let memory: UnsafeMutableRawPointer
    private let handle: lc3_decoder_t
    public let samplesPerFrame: Int

    public init?(frameDurationMicros: Int32 = G2AudioFormat.frameDurationMicros,
                 sampleRate: Int32 = Int32(G2AudioFormat.sampleRate)) {
        let size = Int(lc3_decoder_size(frameDurationMicros, sampleRate))
        let samples = Int(lc3_frame_samples(frameDurationMicros, sampleRate))
        guard size > 0, samples > 0 else { return nil }
        let mem = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        guard let h = lc3_setup_decoder(frameDurationMicros, sampleRate, 0, mem) else {
            mem.deallocate()
            return nil
        }
        memory = mem
        handle = h
        samplesPerFrame = samples
    }

    deinit { memory.deallocate() }

    /// Decodes one frame into `output` (must hold `samplesPerFrame` samples).
    /// Returns false if liblc3 rejected the parameters. A corrupt frame is concealed, not rejected.
    @discardableResult
    public func decode(_ frame: UnsafeRawBufferPointer, into output: UnsafeMutablePointer<Int16>) -> Bool {
        lc3_decode(handle, frame.baseAddress, Int32(frame.count), LC3_PCM_FORMAT_S16, output, 1) >= 0
    }

    /// Packet-loss concealment: synthesizes one frame to bridge a gap.
    @discardableResult
    public func conceal(into output: UnsafeMutablePointer<Int16>) -> Bool {
        lc3_decode(handle, nil, 0, LC3_PCM_FORMAT_S16, output, 1) >= 0
    }
}

public struct G2AudioStats: Equatable, Sendable {
    public var packets = 0
    public var concealedPackets = 0
    public var duplicatePackets = 0
    public var resyncs = 0
    public var malformedPackets = 0
    public init() {}
}

/// Turns 205-byte G2 packets into 16 kHz mono Int16 PCM, concealing small gaps so
/// downstream speech recognition never sees a timing jump.
public final class G2AudioDecoder {
    public enum ChunkKind: Sendable { case real, concealed }

    private let lc3: LC3Decoder
    private var lastCounter: Int?
    private let maxConcealedPackets: Int
    public private(set) var stats = G2AudioStats()

    public init?(maxConcealedPackets: Int = 8) {
        guard let d = LC3Decoder() else { return nil }
        lc3 = d
        self.maxConcealedPackets = maxConcealedPackets
    }

    /// Forget the previous packet counter (call when a new mic session starts).
    public func reset() {
        lastCounter = nil
    }

    /// Feed one BLE notification. `onChunk` receives 800 samples per packet (and per concealed packet).
    public func feed(_ packet: [UInt8], onChunk: ([Int16], ChunkKind) -> Void) {
        guard packet.count == G2AudioFormat.packetBytes else {
            stats.malformedPackets += 1
            return
        }
        let counter = Int(packet[G2AudioFormat.counterOffset])
        if let last = lastCounter {
            let gap = (counter - last) & 0xFF
            if gap == 0 {
                stats.duplicatePackets += 1
                return
            }
            let missing = gap - 1
            if missing > 0 && missing <= maxConcealedPackets {
                for _ in 0..<missing {
                    onChunk(concealPacket(), .concealed)
                    stats.concealedPackets += 1
                }
            } else if missing > maxConcealedPackets {
                stats.resyncs += 1
            }
        }
        lastCounter = counter
        stats.packets += 1
        onChunk(decodePacket(packet), .real)
    }

    /// Decode a packet without gap tracking.
    public func decodePacket(_ packet: [UInt8]) -> [Int16] {
        var pcm = [Int16](repeating: 0, count: G2AudioFormat.samplesPerPacket)
        packet.withUnsafeBytes { raw in
            pcm.withUnsafeMutableBufferPointer { out in
                for f in 0..<G2AudioFormat.framesPerPacket {
                    let start = f * G2AudioFormat.frameBytes
                    let frame = UnsafeRawBufferPointer(rebasing: raw[start..<(start + G2AudioFormat.frameBytes)])
                    lc3.decode(frame, into: out.baseAddress! + f * G2AudioFormat.samplesPerFrame)
                }
            }
        }
        return pcm
    }

    private func concealPacket() -> [Int16] {
        var pcm = [Int16](repeating: 0, count: G2AudioFormat.samplesPerPacket)
        pcm.withUnsafeMutableBufferPointer { out in
            for f in 0..<G2AudioFormat.framesPerPacket {
                lc3.conceal(into: out.baseAddress! + f * G2AudioFormat.samplesPerFrame)
            }
        }
        return pcm
    }
}

/// Simple software gain with hard clipping, for quiet mics.
public enum PCMGain {
    public static func apply(_ gain: Float, to samples: [Int16]) -> [Int16] {
        guard gain != 1 else { return samples }
        return samples.map { s in
            let v = Float(s) * gain
            return Int16(max(-32768, min(32767, v.rounded())))
        }
    }

    /// RMS level in dBFS (-inf...0), handy for a level meter.
    public static func rmsDBFS(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return -120 }
        var sum: Double = 0
        for s in samples { let d = Double(s) / 32768; sum += d * d }
        let rms = (sum / Double(samples.count)).squareRoot()
        return rms > 0 ? Float(20 * log10(rms)) : -120
    }
}
