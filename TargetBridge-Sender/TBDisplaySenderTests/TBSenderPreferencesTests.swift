import CoreMedia
import XCTest
@testable import TargetBridge

@MainActor
final class TBSenderPreferencesTests: XCTestCase {
    func testLanguageFollowsSystemRegionVariants() {
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: ["de-DE"]), .german)
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: ["zh-Hans-CN"]), .chinese)
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: ["it"]), .italian)
    }

    func testFirstSupportedLanguageOrEnglish() {
        // Upstream 3.6.1: the first supported language in the system's order.
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: ["es-ES", "de-DE"]), .german)
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: ["es-ES"]), .english)
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: []), .english)
    }

    func testBrightnessKeysAreDecoded() {
        XCTAssertEqual(
            TBBrightnessKeyEvent.decode(subtype: 8, data1: (2 << 16) | (0xA << 8)),
            TBBrightnessKeyEvent(isIncrease: true, isPressed: true)
        )
        XCTAssertEqual(
            TBBrightnessKeyEvent.decode(subtype: 8, data1: (3 << 16) | (0xB << 8)),
            TBBrightnessKeyEvent(isIncrease: false, isPressed: false)
        )
    }

    func testOtherSystemEventsAreNotBrightnessKeys() {
        XCTAssertNil(TBBrightnessKeyEvent.decode(subtype: 8, data1: (0 << 16) | (0xA << 8)))
        XCTAssertNil(TBBrightnessKeyEvent.decode(subtype: 7, data1: (2 << 16) | (0xA << 8)))
    }

    func testBrightnessStepsStayInRange() {
        XCTAssertEqual(TBDisplaySenderSession.steppedBrightness(from: 0.5, increase: true), 0.5625)
        XCTAssertEqual(TBDisplaySenderSession.steppedBrightness(from: 1, increase: true), 1)
        XCTAssertEqual(TBDisplaySenderSession.steppedBrightness(from: 0, increase: false), 0)
    }

    func testUncompressedFallsBackLikeAutomaticWhenRawIsUnavailable() {
        let decision = TBDisplaySenderSession.chooseCodec(
            preference: .uncompressed,
            preset: .standard1440p,
            receiverSupportsHEVC: false,
            senderSupportsH264: true,
            senderSupportsHEVC: false
        )
        XCTAssertEqual(decision?.codecType, kCMVideoCodecType_H264)
    }
}
