import XCTest
@testable import TargetBridge

@MainActor
final class TBLowLatencyTests: XCTestCase {
    func testAppliesOnlyWhereAVideoEncoderRuns() {
        for compression in [TBDisplayCodecPreference.automatic, .h264, .hevc] {
            XCTAssertTrue(TBDisplaySenderSession.lowLatencyApplies(to: compression), compression.rawValue)
        }
        for compression in [TBDisplayCodecPreference.uncompressed, .uncompressedEnhanced, .losslessDPCM] {
            XCTAssertFalse(TBDisplaySenderSession.lowLatencyApplies(to: compression), compression.rawValue)
        }
    }

    func testSessionAckAnnouncesLowLatencyOnlyWhenActive() throws {
        let active = TBMonitorCreateSessionAck(accepted: true, displayName: "iMac", displayID: 7, lowLatency: true)
        let activeJSON = String(decoding: try JSONEncoder().encode(active), as: UTF8.self)
        XCTAssertTrue(activeJSON.contains(#""lowLatency":true"#), activeJSON)

        let normal = TBMonitorCreateSessionAck(accepted: true, displayName: "iMac", displayID: 7)
        let normalJSON = String(decoding: try JSONEncoder().encode(normal), as: UTF8.self)
        XCTAssertFalse(normalJSON.contains("lowLatency"), normalJSON)
    }

    func testDetailsDescribeTheState() {
        let off = TBDisplaySenderL10n.lowLatencyDetails(applies: false, active: nil, language: .english)
        XCTAssertTrue(off.hasPrefix("Only for H.264"), off)
        let running = TBDisplaySenderL10n.lowLatencyDetails(applies: true, active: true, language: .english)
        XCTAssertTrue(running.hasSuffix("Active."), running)
        let fallback = TBDisplaySenderL10n.lowLatencyDetails(applies: true, active: false, language: .english)
        XCTAssertTrue(fallback.contains("normal encoder"), fallback)
    }
}
