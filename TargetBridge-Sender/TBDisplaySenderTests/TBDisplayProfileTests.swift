import XCTest
@testable import TargetBridge

@MainActor
final class TBDisplayProfileTests: XCTestCase {
    func testWork5KUsesAnExtendedNative5KDisplay() {
        let settings = TBDisplayProfile.work5K.settings

        XCTAssertEqual(settings.captureSource, .extendedDesktop)
        XCTAssertEqual(settings.capturePreset, .native5k60)
        XCTAssertTrue(settings.matchRenderToStream)
        XCTAssertNil(settings.audioEnabled)
    }

    func testLowLatencyPrioritizesSmoothVideoWithoutAudio() {
        let settings = TBDisplayProfile.lowLatency.settings

        XCTAssertEqual(settings.captureSource, .desktopMirror)
        XCTAssertEqual(settings.capturePreset, .smooth1440p60)
        XCTAssertFalse(settings.matchRenderToStream)
        XCTAssertNil(settings.audioEnabled)
    }

    func testPresentationUsesACompatibleMirrorProfileWithAudio() {
        let settings = TBDisplayProfile.presentation.settings

        XCTAssertEqual(settings.captureSource, .desktopMirror)
        XCTAssertEqual(settings.capturePreset, .standard1440p)
        XCTAssertEqual(settings.audioEnabled, true)
    }

    func testEveryProfileUsesItsIntendedCompression() {
        let fiveK = TBDisplayProfile.work5K.settings
        XCTAssertEqual(fiveK.codecPreference, .uncompressedEnhanced)
        XCTAssertEqual(fiveK.codecPreference.method, .lz4)
        XCTAssertEqual(fiveK.codecPreference.colorDepth, .tenBitDithered)
        XCTAssertTrue(fiveK.parallelStreams)

        for profile in [TBDisplayProfile.lowLatency, .presentation] {
            XCTAssertEqual(profile.settings.codecPreference, .automatic, profile.rawValue)
        }
        for profile in TBDisplayProfile.allCases {
            XCTAssertEqual(profile.settings.colorSpacePreference, .automatic, profile.rawValue)
        }
    }

    func testAudioPreferenceRepairRestoresOnlyTheAmbiguousDisabledState() {
        XCTAssertTrue(TBDisplaySenderService.restoredAudioEnabled(from: false, repairPending: true))
        XCTAssertFalse(TBDisplaySenderService.restoredAudioEnabled(from: false, repairPending: false))
        XCTAssertTrue(TBDisplaySenderService.restoredAudioEnabled(from: true, repairPending: false))
    }
}
