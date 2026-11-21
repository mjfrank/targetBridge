import CoreVideo
import XCTest
@testable import TargetBridge

@MainActor
final class TBLatencyTests: XCTestCase {
    func testTargets() {
        for compression in [TBDisplayCodecPreference.automatic, .h264, .hevc] {
            XCTAssertEqual(TBLatencyTarget.of(compression), .encoder, compression.rawValue)
        }
        for compression in [TBDisplayCodecPreference.uncompressed, .uncompressedLZ4, .uncompressedEnhanced,
                            .uncompressedFull10Bit, .uncompressedDithered, .uncompressedTenBit] {
            XCTAssertEqual(TBLatencyTarget.of(compression), .rows, compression.rawValue)
        }
        XCTAssertEqual(TBLatencyTarget.of(.losslessDPCM), TBLatencyTarget.none)
        XCTAssertEqual(TBLatencyTarget.of(.losslessDPCM8Bit), TBLatencyTarget.none)
    }

    func testRowScale() {
        let frame = 1.0 / 60
        XCTAssertEqual(TBLatencyLimits.rowScale(seconds: 0.1, frameInterval: frame, mode: .standard), 1)
        XCTAssertEqual(TBLatencyLimits.rowScale(seconds: 1.5 * frame, frameInterval: frame, mode: .balanced), 1)
        XCTAssertEqual(TBLatencyLimits.rowScale(seconds: 3 * frame, frameInterval: frame, mode: .balanced), 2)
        XCTAssertEqual(TBLatencyLimits.rowScale(seconds: 20 * frame, frameInterval: frame, mode: .balanced), 2)
        XCTAssertEqual(TBLatencyLimits.rowScale(seconds: 0.9 * frame, frameInterval: frame, mode: .low), 1)
        XCTAssertEqual(TBLatencyLimits.rowScale(seconds: 3 * frame, frameInterval: frame, mode: .low), 2)
        XCTAssertEqual(TBLatencyLimits.rowScale(seconds: 5 * frame, frameInterval: frame, mode: .low), 4)
        // Unknown link speed: nothing is reduced.
        XCTAssertEqual(TBLatencyLimits.rowScale(seconds: 0, frameInterval: frame, mode: .low), 1)
    }

    func testEncoderLimits() throws {
        let limits = try XCTUnwrap(TBLatencyLimits.encoderDataRateLimits(
            averageBitRate: 120_000_000, peakBitRate: nil, frameRate: 60))
        XCTAssertEqual(limits.count, 2)
        XCTAssertEqual(limits[1], 0.05, accuracy: 1e-9)
        XCTAssertEqual(limits[0], 120_000_000 / 8 * 1.5 * 0.05, accuracy: 1)
        let withPeak = try XCTUnwrap(TBLatencyLimits.encoderDataRateLimits(
            averageBitRate: 120_000_000, peakBitRate: 180_000_000, frameRate: 60))
        XCTAssertEqual(withPeak.count, 4)
        XCTAssertEqual(withPeak[0], 180_000_000 / 8, accuracy: 1)
        XCTAssertEqual(withPeak[1], 1.0)
    }

    func testAlignment() {
        // Far enough apart that the merge gap keeps them separate.
        let spans = [TBRawRowSpan(start: 2, end: 6), TBRawRowSpan(start: 62, end: 66)]
        XCTAssertEqual(TBRawRegionPlanner.aligned(spans, to: 8, height: 128),
                       [TBRawRowSpan(start: 0, end: 8), TBRawRowSpan(start: 56, end: 72)])
        XCTAssertEqual(TBRawRegionPlanner.aligned([TBRawRowSpan(start: 118, end: 124)], to: 8, height: 128),
                       [TBRawRowSpan(start: 112, end: 128)])
        XCTAssertNil(TBRawRegionPlanner.aligned(spans, to: 8, height: 60))
    }

    func testScaledPacket() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
                                           kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer),
                       kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        let built = try XCTUnwrap(TBRawRegionPacketBuilder.makePackets(
            pixelBuffer: pixelBuffer, spans: [TBRawRowSpan(start: 0, end: 16)], fullFrame: true,
            compress: false, parts: 1, frameSequence: nil, scale: 2))
        XCTAssertEqual(built.summary.scale, 2)
        XCTAssertEqual(built.summary.rows, 16)
        // 8x8 luma + 4 CbCr rows of 8 bytes.
        XCTAssertEqual(built.summary.rawBytes, 8 * 8 + 4 * 8)
        let packet = try XCTUnwrap(built.packets.first)
        // [4 length][1 type][14 header][13 band entry]: the encoding byte is last.
        XCTAssertEqual(packet[5 + 14 + 12], 0x10)

        // Misaligned rows fall back to full size.
        let unaligned = try XCTUnwrap(TBRawRegionPacketBuilder.makePackets(
            pixelBuffer: pixelBuffer, spans: [TBRawRowSpan(start: 2, end: 8)], fullFrame: false,
            compress: false, parts: 1, frameSequence: nil, scale: 2))
        XCTAssertEqual(unaligned.summary.scale, 1)
    }

    func testSessionAckCarriesTheLatency() throws {
        let low = TBMonitorCreateSessionAck(accepted: true, displayName: "iMac", displayID: 7, latency: "low")
        let lowJSON = String(decoding: try JSONEncoder().encode(low), as: UTF8.self)
        XCTAssertTrue(lowJSON.contains(#""latency":"low""#), lowJSON)
        let standard = TBMonitorCreateSessionAck(accepted: true, displayName: "iMac", displayID: 7)
        let standardJSON = String(decoding: try JSONEncoder().encode(standard), as: UTF8.self)
        XCTAssertFalse(standardJSON.contains("latency"), standardJSON)
    }

    func testDetailsExplainEachSettingForTheCompression() {
        let rows = TBDisplaySenderL10n.latencyDetails(selected: .balanced, target: .rows,
                                                      receiverSupportsScaledRows: true, active: nil,
                                                      streaming: false, language: .english)
        let lines = rows.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("Balanced: "), lines[0])
        XCTAssertTrue(lines[0].contains("half resolution"), lines[0])

        let encoder = TBDisplaySenderL10n.latencyDetails(selected: .low, target: .encoder,
                                                         receiverSupportsScaledRows: nil, active: .low,
                                                         streaming: true, language: .english)
        XCTAssertTrue(encoder.hasPrefix("Low: Apple's real-time"), encoder)
        XCTAssertTrue(encoder.hasSuffix("Active."), encoder)

        let older = TBDisplaySenderL10n.latencyDetails(selected: .low, target: .rows,
                                                       receiverSupportsScaledRows: false, active: .standard,
                                                       streaming: true, language: .english)
        XCTAssertTrue(older.contains("update it"), older)
        XCTAssertTrue(older.hasSuffix("Standard applies."), older)

        let dpcm = TBDisplaySenderL10n.latencyDetails(selected: .low, target: .none,
                                                      receiverSupportsScaledRows: true, active: nil,
                                                      streaming: false, language: .english)
        XCTAssertTrue(dpcm.hasPrefix("DPCM"), dpcm)
    }
}
