import XCTest
@testable import TargetBridge

@MainActor
final class TBDisplayProfileTests: XCTestCase {
    func testDefaultsKeepTheirStreamProfilesAndOldIdentifiers() {
        let defaults = TBDisplayProfile.defaults
        XCTAssertEqual(defaults.map(\.id), ["work5K", "lowLatency", "presentation"])
        XCTAssertEqual(defaults.map(\.capturePreset), [.native5k, .smooth1440p60, .standard1440p])
        XCTAssertTrue(defaults.allSatisfy { $0.codecPreference == .automatic && $0.parallelStreams })
        XCTAssertEqual(defaults[0].title(.english), "Work 5K")
        XCTAssertEqual(defaults[1].title(.english), "Low latency")
        XCTAssertEqual(defaults[2].title(.german), TBDisplaySenderL10n.text("sender.display_profiles.presentation", .german))
    }

    func testRenamedProfileUsesItsOwnName() {
        var profile = TBDisplayProfile.defaults[0]
        profile.name = "  Office  "
        XCTAssertEqual(profile.title(.english), "Office")
        let untitled = TBDisplayProfile(name: " ", capturePreset: .standard1440p)
        XCTAssertEqual(untitled.title(.english), "Untitled profile")
    }

    func testCompressionFollowsWhatTheStreamProfileAllows() {
        // An uncompressed-mode stream profile only allows the uncompressed modes.
        let raw = TBDisplayProfile(name: "Raw", capturePreset: .native5k60Full10Bit, codecPreference: .hevc)
        XCTAssertEqual(raw.effectiveCodecPreference, .uncompressedFull10Bit)
        let dpcm = TBDisplayProfile(name: "DPCM", capturePreset: .native5k60Full10Bit, codecPreference: .losslessDPCM)
        XCTAssertEqual(dpcm.effectiveCodecPreference, .losslessDPCM)
        let hevc = TBDisplayProfile(name: "HEVC", capturePreset: .smooth1440p60, codecPreference: .hevc)
        XCTAssertEqual(hevc.effectiveCodecPreference, .hevc)
        // The 10-bit changed-rows modes need parallel connections.
        let tenBit = TBDisplayProfile(name: "10", capturePreset: .native5k60Enhanced10Bit, parallelStreams: false)
        XCTAssertTrue(tenBit.effectiveParallelStreams)
        let lz4 = TBDisplayProfile(name: "LZ4", capturePreset: .native5k60UncompressedLZ4, parallelStreams: false)
        XCTAssertFalse(lz4.effectiveParallelStreams)
    }

    func testListRoundTripsAndToleratesUnknownValues() throws {
        let list = TBDisplayProfile.defaults + [
            TBDisplayProfile(name: "Mine", capturePreset: .native5k60DPCM, codecPreference: .losslessDPCM, parallelStreams: false)
        ]
        let data = try XCTUnwrap(TBDisplayProfile.encodeList(list))
        XCTAssertEqual(TBDisplayProfile.decodeList(data), list)

        let future = #"[{"id":"x","name":"Future","capturePreset":"native8k","codecPreference":"av2","parallelStreams":false}]"#
        let decoded = try XCTUnwrap(TBDisplayProfile.decodeList(Data(future.utf8)))
        XCTAssertEqual(decoded.first?.capturePreset, .standard1440p)
        XCTAssertEqual(decoded.first?.codecPreference, .automatic)
        XCTAssertEqual(decoded.first?.parallelStreams, false)

        // An empty list is a valid choice (everything removed), not "nothing saved".
        XCTAssertEqual(TBDisplayProfile.decodeList(Data("[]".utf8)), [])
        XCTAssertNil(TBDisplayProfile.decodeList(nil))
    }

    func testAudioPreferenceRepairRestoresOnlyTheAmbiguousDisabledState() {
        XCTAssertTrue(TBDisplaySenderService.restoredAudioEnabled(from: false, repairPending: true))
        XCTAssertFalse(TBDisplaySenderService.restoredAudioEnabled(from: false, repairPending: false))
        XCTAssertTrue(TBDisplaySenderService.restoredAudioEnabled(from: true, repairPending: false))
    }
}
