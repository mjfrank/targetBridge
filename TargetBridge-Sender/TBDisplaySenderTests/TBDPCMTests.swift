import CoreVideo
import XCTest
@testable import TargetBridge

/// Lossless DPCM (upstream pull request #201): the encoder, its packet and the
/// option's place among the compression modes. Adapted from #201's tests.
@MainActor
final class TBDPCMTests: XCTestCase {
    private func buffer(format: OSType, width: Int = 1024, height: Int = 3) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    func testCPUEncoderPreservesAllTenBits() throws {
        let pixelBuffer = try buffer(format: kCVPixelFormatType_ARGB2101010LEPacked)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, []), kCVReturnSuccess)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for channel in 0..<3 {
            let row = base.advanced(by: channel * stride).assumingMemoryBound(to: UInt32.self)
            for level in 0..<1024 { row[level] = (3 << 30) | (UInt32(level) << (channel * 10)) }
        }
        let original = Data(bytes: base, count: stride * 3)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        for adaptive in [false, true] {
            let payload = try XCTUnwrap(TBDPCMFrameEncoder(useGPU: false, adaptiveColor: adaptive).encode(pixelBuffer))
            var info = tb_dpcm_info()
            var decoded = Data(count: stride * 3)
            payload.withUnsafeBytes { raw in
                let input = raw.bindMemory(to: UInt8.self).baseAddress
                XCTAssertEqual(tb_dpcm_parse(input, payload.count, &info), 0)
                XCTAssertEqual(info.ten_bit, 1)
                XCTAssertEqual(info.width, 1024)
                XCTAssertEqual(info.height, 3)
                decoded.withUnsafeMutableBytes { output in
                    XCTAssertEqual(tb_dpcm_decode(input, payload.count,
                                                  output.bindMemory(to: UInt8.self).baseAddress, Int32(stride)), 0)
                }
            }
            for channel in 0..<3 {
                let row = channel * stride..<(channel * stride + 4096)
                XCTAssertEqual(decoded.subdata(in: row), original.subdata(in: row), "adaptive=\(adaptive)")
            }
        }
    }

    func testEncoderRejectsOtherFormatsInsteadOfReinterpretingThem() throws {
        let encoder = TBDPCMFrameEncoder(useGPU: false)
        for pixelBuffer in [
            try buffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 64, height: 64),
            try buffer(format: kCVPixelFormatType_32BGRA),
            try buffer(format: kCVPixelFormatType_ARGB2101010LEPacked, width: 5121)
        ] {
            XCTAssertNil(encoder.encode(pixelBuffer))
            XCTAssertNil(encoder.encodePacket(pixelBuffer))
        }
    }

    func testPacketUsesTypeTwentySevenAndTheBlobAsPayload() throws {
        let pixelBuffer = try buffer(format: kCVPixelFormatType_ARGB2101010LEPacked, width: 64, height: 16)
        let encoder = TBDPCMFrameEncoder(useGPU: false)
        let blob = try XCTUnwrap(encoder.encode(pixelBuffer))
        let packet = try XCTUnwrap(encoder.encodePacket(pixelBuffer))
        XCTAssertEqual(TBMonitorPacketType.rawDPCM.rawValue, 0x27)
        XCTAssertEqual(packet[4], 0x27)
        let length = packet.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        XCTAssertEqual(Int(length), 1 + blob.count)
        XCTAssertEqual(packet.dropFirst(5), blob)
        // 'TBD2' little endian.
        XCTAssertEqual(Array(blob.prefix(4)), Array("TBD2".utf8))
    }

    func testDPCMIsAnUncompressedFamilyMode() {
        XCTAssertTrue(TBDisplayCodecPreference.losslessDPCM.usesRawFrames)
        XCTAssertTrue(TBDisplayCodecPreference.losslessDPCM.compressesRawFrames)
        XCTAssertFalse(TBDisplayCodecPreference.losslessDPCM.needsParallelStreams)
    }

    func testReceiverCapabilitiesDecode() throws {
        let json = #"{"receiverName":"iMac","panelWidth":5120,"panelHeight":2880,"modeWidth":2560,"modeHeight":1440,"#
            + #""refreshRate":60,"hiDPI":true,"captureWidth":5120,"captureHeight":2880,"#
            + #""supportsDPCM":true,"supportsDPCMAdaptiveColor":true}"#
        let profile = try JSONDecoder().decode(TBMonitorDisplayProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.supportsDPCM, true)
        XCTAssertEqual(profile.supportsDPCMAdaptiveColor, true)
    }

    func testLabelsNameBothLosslessModes() {
        XCTAssertEqual(TBDisplaySenderL10n.codecPreferenceTitle(.losslessDPCM, language: .english),
                       "Lossless 10-bit · full frames (DPCM, experimental)")
        XCTAssertEqual(TBDisplaySenderL10n.codecPreferenceTitle(.uncompressedFull10Bit, language: .english),
                       "Lossless 10-bit · changed rows (LZ4, experimental)")
        XCTAssertEqual(TBSenderAutomation.parsePresetCompression("5k60dpcm"), .losslessDPCM)
    }
}
