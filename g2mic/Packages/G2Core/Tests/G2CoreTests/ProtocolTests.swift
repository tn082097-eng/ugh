import XCTest
@testable import G2Core

private func hex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

final class ProtocolTests: XCTestCase {
    func testCRCCheckValue() {
        XCTAssertEqual(CRC16.ccittFalse(Array("123456789".utf8)), 0x29B1)
    }

    /// The prelude frame captured from the official app on real hardware must be
    /// reproduced byte-for-byte by our framing + CRC.
    func testPreludeMatchesHardwareCapture() {
        let captured = hex("aa219213010101200802109c01220a1a081206120408001000a142")
        let frames = Envelope.frame(payload: AppLaunch.preludePayload, seq: AppLaunch.preludeSeq, sid: AppLaunch.sid)
        XCTAssertEqual(frames, [captured])
    }

    // Golden vectors below were produced by protobuf (Python) from the EvenHub schema
    // reconstructed by g2-kit, i.e. an independent encoder.
    func testAudioControlEncoding() {
        XCTAssertEqual(EvenHub.audioControl(enable: true, magic: 0xA1), hex("080f10a1019201020801"))
        XCTAssertEqual(EvenHub.audioControl(enable: false, magic: 0xA2), hex("080f10a201920100"))
    }

    func testHeartbeatEncoding() {
        XCTAssertEqual(EvenHub.heartbeat(magic: 101), hex("080c10657200"))
    }

    func testCreateStartupPageEncoding() {
        XCTAssertEqual(
            EvenHub.createStartupPage(name: "g2mic", items: ["G2 Mic listening"], magic: 100),
            hex("10641a30080112291898022082014801520567326d69635a160801180122104732204d6963206c697374656e696e67600128904e")
        )
    }

    func testRebuildTextEncoding() {
        XCTAssertEqual(
            EvenHub.rebuildWithText(name: "g2mic-t", text: "hello wörld", magic: 102),
            hex("080710663a2308011a1f18c00420a0024801520767326d69632d74620c68656c6c6f2077c3b6726c64")
        )
    }

    func testFragmentationSharesSeqAndPutsCRCOnLastFragment() {
        let payload = (0..<500).map { UInt8($0 & 0xFF) }
        let frames = Envelope.frame(payload: payload, seq: 0x41, sid: 0xE0)
        XCTAssertEqual(frames.count, 3) // 502 bytes incl. CRC / 232
        for (i, f) in frames.enumerated() {
            XCTAssertEqual(Array(f[0..<3]), [0xAA, 0x21, 0x41])
            XCTAssertEqual(f[3], UInt8(f.count - 8))
            XCTAssertEqual(f[4], 3)
            XCTAssertEqual(f[5], UInt8(i + 1))
            XCTAssertEqual(f[6], 0xE0)
            XCTAssertEqual(f[7], 0x20)
        }
        // Reassemble (pretend they came from the glasses) and check CRC.
        var r = EnvelopeReassembler()
        var result: EnvelopeMessage?
        for f in frames {
            var rx = f
            rx[1] = 0x12
            result = r.push(rx) ?? result
        }
        XCTAssertEqual(result?.payload, payload)
        XCTAssertEqual(result?.crcValid, true)
    }

    func testAckParsing() {
        // A heartbeat reply: Cmd=13, magic=101.
        var w = ProtoWriter()
        w.uint(1, 13)
        w.uint(2, 101)
        var frame = Envelope.frame(payload: w.bytes, seq: 7, sid: 0xE0, flag: 0x00)[0]
        frame[1] = 0x12
        var r = EnvelopeReassembler()
        let msg = r.push(frame)
        XCTAssertEqual(msg?.sid, 0xE0)
        XCTAssertEqual(msg?.command, 13)
        XCTAssertEqual(msg?.magic, 101)
    }

    func testAudioStatusParsing() {
        var w = ProtoWriter()
        w.uint(1, EvenHub.Cmd.audioControlResponse.rawValue)
        w.uint(2, 0xA1)
        w.message(19) { $0.uint(1, 1) }
        let msg = EnvelopeMessage(sid: 0xE0, flag: 0, payload: w.bytes, crcValid: true)
        XCTAssertEqual(EvenHub.audioStatus(from: msg), 1)
    }

    func testArmNameParsing() {
        XCTAssertEqual(G2Arm.from(advertisedName: "Even G2_32_L_ABC123"), .left)
        XCTAssertEqual(G2Arm.from(advertisedName: "Even G2_32_R_ABC123"), .right)
        XCTAssertEqual(G2Arm.from(advertisedName: "G2_7_r_x"), .right)
        XCTAssertNil(G2Arm.from(advertisedName: "AirPods Pro"))
        XCTAssertNil(G2Arm.from(advertisedName: nil))
    }

    func testTextTruncationKeepsWholeCharacters() {
        let s = String(repeating: "ö", count: 600) // 1200 bytes
        let t = EvenHub.truncateUTF8(s, maxBytes: 901)
        XCTAssertEqual(t.utf8.count, 900)
    }
}

final class ProvisioningProfileTests: XCTestCase {
    func testReadsAppGroupFromSignedProfileBlob() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Entitlements</key><dict>
            <key>com.apple.security.application-groups</key>
            <array><string>group.com.example.g2mic.ABCDE12345</string></array>
          </dict>
        </dict></plist>
        """
        // Real profiles wrap the plist in binary CMS data.
        var blob = Data([0x30, 0x82, 0x1F, 0x00, 0xFF, 0x00])
        blob.append(Data(plist.utf8))
        blob.append(Data([0x00, 0xA0, 0x82, 0x0B]))
        XCTAssertEqual(ProvisioningProfile.appGroup(fromProfileData: blob), "group.com.example.g2mic.ABCDE12345")
    }

    func testNoProfileMeansNil() {
        XCTAssertNil(ProvisioningProfile.appGroup(fromProfileData: Data([1, 2, 3])))
    }
}
