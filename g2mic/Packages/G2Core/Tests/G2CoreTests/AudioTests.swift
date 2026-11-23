import XCTest
import CLC3
@testable import G2Core

final class AudioTests: XCTestCase {
    /// Encode a synthetic voice-band signal with liblc3 at the G2's settings, pack it into
    /// 205-byte G2 packets, then make sure G2AudioDecoder reproduces it.
    private func makePackets(count: Int) -> (packets: [[UInt8]], source: [Int16]) {
        let dt = G2AudioFormat.frameDurationMicros
        let sr = Int32(G2AudioFormat.sampleRate)
        let mem = UnsafeMutableRawPointer.allocate(byteCount: Int(lc3_encoder_size(dt, sr)), alignment: 16)
        defer { mem.deallocate() }
        let enc = lc3_setup_encoder(dt, sr, 0, mem)!
        let total = count * G2AudioFormat.samplesPerPacket
        let source: [Int16] = (0..<total).map { i in
            let t = Double(i) / 16000
            return Int16(7000 * sin(2 * .pi * 300 * t) + 3000 * sin(2 * .pi * 1100 * t))
        }
        var packets: [[UInt8]] = []
        for p in 0..<count {
            var packet = [UInt8](repeating: 0, count: G2AudioFormat.packetBytes)
            for f in 0..<G2AudioFormat.framesPerPacket {
                let sampleStart = (p * G2AudioFormat.framesPerPacket + f) * G2AudioFormat.samplesPerFrame
                source.withUnsafeBufferPointer { src in
                    packet.withUnsafeMutableBytes { out in
                        let rc = lc3_encode(enc, LC3_PCM_FORMAT_S16, src.baseAddress! + sampleStart, 1,
                                            Int32(G2AudioFormat.frameBytes),
                                            out.baseAddress! + f * G2AudioFormat.frameBytes)
                        XCTAssertEqual(rc, 0)
                    }
                }
            }
            packet[G2AudioFormat.counterOffset] = UInt8(p & 0xFF)
            packets.append(packet)
        }
        return (packets, source)
    }

    func testDecodesG2PacketsBackToTheSignal() throws {
        let (packets, source) = makePackets(count: 40)
        let decoder = try XCTUnwrap(G2AudioDecoder())
        var pcm: [Int16] = []
        for p in packets { decoder.feed(p) { chunk, _ in pcm += chunk } }
        XCTAssertEqual(pcm.count, source.count)
        XCTAssertEqual(decoder.stats.packets, 40)

        let delay = Int(lc3_delay_samples(G2AudioFormat.frameDurationMicros, Int32(G2AudioFormat.sampleRate)))
        var signal = 0.0, noise = 0.0
        for i in 1600..<pcm.count {
            let a = Double(source[i - delay]), b = Double(pcm[i])
            signal += a * a
            noise += (a - b) * (a - b)
        }
        let snr = 10 * log10(signal / noise)
        XCTAssertGreaterThan(snr, 8, "decoded audio should resemble the input (SNR \(snr) dB)")
    }

    func testConcealsSmallGapsAndDropsDuplicates() throws {
        let (packets, _) = makePackets(count: 6)
        let decoder = try XCTUnwrap(G2AudioDecoder())
        var kinds: [G2AudioDecoder.ChunkKind] = []
        // Deliver 0, 1, 1 (dup), 4 (2 and 3 lost), 5.
        for i in [0, 1, 1, 4, 5] { decoder.feed(packets[i]) { _, k in kinds.append(k) } }
        XCTAssertEqual(kinds, [.real, .real, .concealed, .concealed, .real, .real])
        XCTAssertEqual(decoder.stats.duplicatePackets, 1)
        XCTAssertEqual(decoder.stats.concealedPackets, 2)
    }

    func testRejectsWrongSizedPackets() throws {
        let decoder = try XCTUnwrap(G2AudioDecoder())
        var called = false
        decoder.feed([1, 2, 3]) { _, _ in called = true }
        XCTAssertFalse(called)
        XCTAssertEqual(decoder.stats.malformedPackets, 1)
    }

    func testWAVHeader() {
        let d = WAV.file(samples: [1, -1, 300])
        XCTAssertEqual(d.count, 44 + 6)
        XCTAssertEqual(Array(d[0..<4]), Array("RIFF".utf8))
        XCTAssertEqual(Array(d[36..<40]), Array("data".utf8))
    }

    func testGainClips() {
        XCTAssertEqual(PCMGain.apply(4, to: [10_000, -10_000, 5]), [32767, -32768, 20])
    }
}
