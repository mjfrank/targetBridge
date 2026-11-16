import XCTest
@testable import TargetBridge

@MainActor
final class TBVideoColorSpaceTests: XCTestCase {
    func testReceiverWithoutColourManagementStaysUnlabelled() {
        for preference in TBVideoColorSpacePreference.allCases {
            XCTAssertNil(TBVideoColorSpace.resolve(preference: preference,
                                                   receiverSupportsTags: false,
                                                   receiverPanelColorSpace: "displayP3"))
        }
    }

    func testAutomaticFollowsThePanel() {
        XCTAssertEqual(TBVideoColorSpace.resolve(preference: .automatic,
                                                 receiverSupportsTags: true,
                                                 receiverPanelColorSpace: "displayP3"), .displayP3)
        XCTAssertEqual(TBVideoColorSpace.resolve(preference: .automatic,
                                                 receiverSupportsTags: true,
                                                 receiverPanelColorSpace: "srgb"), .sRGB)
        // An unknown panel is treated as sRGB, the safe choice.
        XCTAssertEqual(TBVideoColorSpace.resolve(preference: .automatic,
                                                 receiverSupportsTags: true,
                                                 receiverPanelColorSpace: nil), .sRGB)
    }

    func testExplicitChoiceWins() {
        XCTAssertEqual(TBVideoColorSpace.resolve(preference: .sRGB,
                                                 receiverSupportsTags: true,
                                                 receiverPanelColorSpace: "displayP3"), .sRGB)
        XCTAssertEqual(TBVideoColorSpace.resolve(preference: .displayP3,
                                                 receiverSupportsTags: true,
                                                 receiverPanelColorSpace: "srgb"), .displayP3)
    }

    func testProfileFieldsDecodeAndOlderProfilesStayUnlabelled() throws {
        let newer = try JSONDecoder().decode(TBMonitorDisplayProfile.self, from: Data(profileJSON(
            extra: #","supportsColorSpaceTags":true,"panelColorSpace":"displayP3""#).utf8))
        XCTAssertEqual(newer.supportsColorSpaceTags, true)
        XCTAssertEqual(newer.panelColorSpace, "displayP3")
        XCTAssertEqual(TBVideoColorSpace.resolve(preference: .automatic, profile: newer), .displayP3)

        let older = try JSONDecoder().decode(TBMonitorDisplayProfile.self, from: Data(profileJSON(extra: "").utf8))
        XCTAssertNil(older.supportsColorSpaceTags)
        XCTAssertNil(TBVideoColorSpace.resolve(preference: .displayP3, profile: older))
    }

    func testSessionAckAnnouncesTheColourSpaceOnlyWhenLabelled() throws {
        let labelled = TBMonitorCreateSessionAck(accepted: true, displayName: "iMac", displayID: 7,
                                                 colorSpace: TBVideoColorSpace.displayP3.rawValue)
        let labelledJSON = String(decoding: try JSONEncoder().encode(labelled), as: UTF8.self)
        XCTAssertTrue(labelledJSON.contains(#""colorSpace":"displayP3""#), labelledJSON)

        let unlabelled = TBMonitorCreateSessionAck(accepted: true, displayName: "iMac", displayID: 7)
        let unlabelledJSON = String(decoding: try JSONEncoder().encode(unlabelled), as: UTF8.self)
        XCTAssertFalse(unlabelledJSON.contains("colorSpace"), unlabelledJSON)
    }

    func testWireNamesMatchTheReceiver() {
        // color_space.h: TB_COLOR_SPACE_NAME_SRGB / TB_COLOR_SPACE_NAME_DISPLAY_P3.
        XCTAssertEqual(TBVideoColorSpace.sRGB.rawValue, "srgb")
        XCTAssertEqual(TBVideoColorSpace.displayP3.rawValue, "displayP3")
    }

    func testVirtualDisplayPrimaries() {
        // Unlabelled sessions keep the primaries used before colour labelling.
        let unlabelled = ReceiverBackedVirtualDisplaySession.chromaticities(for: nil)
        XCTAssertEqual(unlabelled.red, CGPoint(x: 0.6797, y: 0.3203))
        XCTAssertEqual(unlabelled.white, CGPoint(x: 0.3125, y: 0.3291))

        let srgb = ReceiverBackedVirtualDisplaySession.chromaticities(for: .sRGB)
        XCTAssertEqual(srgb.red, CGPoint(x: 0.64, y: 0.33))
        XCTAssertEqual(srgb.green, CGPoint(x: 0.30, y: 0.60))
        XCTAssertEqual(srgb.blue, CGPoint(x: 0.15, y: 0.06))

        let p3 = ReceiverBackedVirtualDisplaySession.chromaticities(for: .displayP3)
        XCTAssertEqual(p3.red, CGPoint(x: 0.680, y: 0.320))
        XCTAssertEqual(p3.green, CGPoint(x: 0.265, y: 0.690))
        XCTAssertEqual(p3.white, CGPoint(x: 0.3127, y: 0.3290))
    }

    func testCaptureAndStreamTags() {
        XCTAssertEqual(TBVideoColorSpace.sRGB.cgColorSpaceName, CGColorSpace.sRGB)
        XCTAssertEqual(TBVideoColorSpace.displayP3.cgColorSpaceName, CGColorSpace.displayP3)
        XCTAssertEqual(TBVideoColorSpace.sRGB.videoColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        XCTAssertEqual(TBVideoColorSpace.displayP3.videoColorPrimaries, kCVImageBufferColorPrimaries_P3_D65)
    }

    func testDetailsNameTheActiveColourSpace() {
        let streaming = TBDisplaySenderL10n.colorSpaceDetails(active: .displayP3, receiverSupportsTags: true,
                                                              streaming: true, language: .english)
        XCTAssertTrue(streaming.hasSuffix("Active: Display P3."), streaming)
        let older = TBDisplaySenderL10n.colorSpaceDetails(active: nil, receiverSupportsTags: false,
                                                          streaming: true, language: .english)
        XCTAssertTrue(older.contains("not labelled"), older)
        let idle = TBDisplaySenderL10n.colorSpaceDetails(active: nil, receiverSupportsTags: nil,
                                                         streaming: false, language: .english)
        XCTAssertFalse(idle.contains("Active"), idle)
    }

    private func profileJSON(extra: String) -> String {
        #"{"receiverName":"iMac","panelWidth":5120,"panelHeight":2880,"modeWidth":2560,"modeHeight":1440,"#
            + #""refreshRate":60,"hiDPI":true,"captureWidth":5120,"captureHeight":2880"# + extra + "}"
    }
}
