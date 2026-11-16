import XCTest
@testable import TargetBridge

@MainActor
final class TBVersionCheckTests: XCTestCase {
    func testVersionsCompareNumerically() {
        XCTAssertEqual(TBVersionCheck.compare("4.0", "4.0.0"), .orderedSame)
        XCTAssertEqual(TBVersionCheck.compare("3.7.0-rc1", "4.0"), .orderedAscending)
        XCTAssertEqual(TBVersionCheck.compare("4.10", "4.9"), .orderedDescending)
        XCTAssertEqual(TBVersionCheck.components("3.7.0-rc1"), [3, 7, 0])
    }

    func testMismatchNamesTheOlderApp() {
        XCTAssertNil(TBVersionCheck.mismatch(sender: "4.0", receiver: "4.0"))
        XCTAssertEqual(TBVersionCheck.mismatch(sender: "4.0", receiver: nil), .receiverOlder(nil))
        XCTAssertEqual(TBVersionCheck.mismatch(sender: "4.0", receiver: "3.6.0"), .receiverOlder("3.6.0"))
        XCTAssertEqual(TBVersionCheck.mismatch(sender: "4.0", receiver: "4.1"), .senderOlder("4.1"))
    }

    func testEarlierProfileNamesMapToResolutionFrameRateAndCompression() {
        let legacy = TBDisplayCapturePreset.legacyProfiles
        XCTAssertEqual(legacy["native5k60Uncompressed"]?.preset, .native5k60)
        XCTAssertEqual(legacy["native5k60Uncompressed"]?.codec, .uncompressed)
        XCTAssertEqual(legacy["native5k60UncompressedLZ4"]?.codec, .uncompressedLZ4)
        XCTAssertEqual(legacy["native5k60Enhanced10Bit"]?.codec, .uncompressedEnhanced)
        XCTAssertEqual(legacy["native5k60Full10Bit"]?.codec, .uncompressedFull10Bit)
        XCTAssertEqual(legacy["native5k60DPCM"]?.codec, .losslessDPCM)
        XCTAssertNil(legacy["native5k60Experimental"]?.codec)
        XCTAssertEqual(TBDisplayCapturePreset(rawValue: "native5k"), .native5k)
        XCTAssertEqual(TBDisplayCapturePreset(rawValue: "smooth1440p60"), .smooth1440p60)
    }

    func testAutomationAcceptsTheEarlierUncompressedNames() {
        for name in ["5k60lz4", "5k60full10", "5k60dpcm", "native5k60Enhanced10Bit"] {
            XCTAssertEqual(TBSenderAutomation.parsePreset(name), .native5k60, name)
        }
        XCTAssertEqual(TBSenderAutomation.parsePresetCompression("5k60lz4"), .uncompressedLZ4)
        XCTAssertEqual(TBSenderAutomation.parsePresetCompression("5k60full10"), .uncompressedFull10Bit)
        XCTAssertEqual(TBSenderAutomation.parsePresetCompression("5k60dpcm"), .losslessDPCM)
        XCTAssertEqual(TBSenderAutomation.parsePresetCompression("native5k60Enhanced10Bit"), .uncompressedEnhanced)
        XCTAssertNil(TBSenderAutomation.parsePresetCompression("5k60"))
    }

}
