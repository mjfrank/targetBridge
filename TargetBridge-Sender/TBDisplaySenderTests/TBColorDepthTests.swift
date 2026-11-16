import XCTest
@testable import TargetBridge

/// Compression is chosen as method + colour depth; each pair maps to one mode.
final class TBColorDepthTests: XCTestCase {
    func testEveryModeRoundTripsThroughMethodAndDepth() {
        for preference in TBDisplayCodecPreference.allCases {
            XCTAssertEqual(TBDisplayCodecPreference.make(method: preference.method, depth: preference.colorDepth),
                           preference, "\(preference)")
        }
    }

    func testCodecsAreEightBitAndDPCMHasNoDitheredVariant() {
        for method in [TBCompressionMethod.automatic, .h264, .hevc] {
            XCTAssertNotNil(TBDisplayCodecPreference.make(method: method, depth: .eightBit))
            XCTAssertNil(TBDisplayCodecPreference.make(method: method, depth: .tenBit))
            XCTAssertNil(TBDisplayCodecPreference.make(method: method, depth: .tenBitDithered))
        }
        XCTAssertNil(TBDisplayCodecPreference.make(method: .dpcm, depth: .tenBitDithered))
        XCTAssertEqual(TBDisplayCodecPreference.make(method: .dpcm, depth: .eightBit), .losslessDPCM8Bit)
        XCTAssertEqual(TBDisplayCodecPreference.make(method: .dpcm, depth: .tenBit), .losslessDPCM)
    }

    func testEarlierModesKeepTheirMeaning() {
        XCTAssertEqual(TBDisplayCodecPreference.make(method: .lz4, depth: .eightBit), .uncompressedLZ4)
        XCTAssertEqual(TBDisplayCodecPreference.make(method: .lz4, depth: .tenBitDithered), .uncompressedEnhanced)
        XCTAssertEqual(TBDisplayCodecPreference.make(method: .lz4, depth: .tenBit), .uncompressedFull10Bit)
        XCTAssertEqual(TBDisplayCodecPreference.make(method: .uncompressed, depth: .eightBit), .uncompressed)
    }

    func testNewModesHaveTheExpectedProperties() {
        XCTAssertFalse(TBDisplayCodecPreference.uncompressedDithered.compressesRawFrames)
        XCTAssertTrue(TBDisplayCodecPreference.uncompressedDithered.dithersTenBit)
        XCTAssertFalse(TBDisplayCodecPreference.uncompressedTenBit.compressesRawFrames)
        XCTAssertTrue(TBDisplayCodecPreference.uncompressedTenBit.sendsFullTenBit)
        XCTAssertTrue(TBDisplayCodecPreference.uncompressedTenBit.needsParallelStreams)
        XCTAssertFalse(TBDisplayCodecPreference.uncompressedDithered.needsParallelStreams)
        XCTAssertTrue(TBDisplayCodecPreference.losslessDPCM8Bit.usesDPCM)
        for preference in TBDisplayCodecPreference.allCases where preference != .automatic
            && preference != .h264 && preference != .hevc {
            XCTAssertTrue(preference.usesRawFrames, "\(preference)")
        }
    }

    func testParallelConnectionsFollowTheCompression() {
        XCTAssertFalse(TBDisplaySenderSession.effectiveParallelStreams(chosen: true, compression: .automatic))
        XCTAssertTrue(TBDisplaySenderSession.effectiveParallelStreams(chosen: false, compression: .uncompressedTenBit))
        XCTAssertFalse(TBDisplaySenderSession.effectiveParallelStreams(chosen: false, compression: .uncompressedLZ4))
        XCTAssertTrue(TBDisplaySenderSession.effectiveParallelStreams(chosen: true, compression: .hevc))
    }

    func testEveryLabelExistsInEveryLanguage() {
        for language in TBDisplaySenderLanguage.allCases {
            for method in TBCompressionMethod.allCases {
                let title = TBDisplaySenderL10n.text("sender.method.\(method.rawValue)", language)
                XCTAssertFalse(title.isEmpty || title.contains("sender.method"), "\(language) \(method)")
            }
            for depth in TBColorDepth.allCases {
                let title = TBDisplaySenderL10n.text("sender.depth.\(depth.rawValue)", language)
                XCTAssertFalse(title.isEmpty || title.contains("sender.depth"), "\(language) \(depth)")
            }
            for preference in TBDisplayCodecPreference.allCases {
                let hint = TBDisplaySenderL10n.codecPreferenceHint(preference, language: language)
                XCTAssertFalse(hint.isEmpty || hint.contains("sender.codec"), "\(language) \(preference)")
            }
        }
    }
}
