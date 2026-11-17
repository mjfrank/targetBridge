import Foundation

struct TBDisplayProfileSettings: Equatable {
    let captureSource: TBDisplayCaptureSource
    let capturePreset: TBDisplayCapturePreset
    let matchRenderToStream: Bool
    /// `nil` keeps the user's existing audio preference when a display profile
    /// is applied. A display profile should tune video without silently
    /// disabling audio for future sessions.
    let audioEnabled: Bool?
    /// Compression, parallel connections and colour space the profile was
    /// designed for: Automatic picks H.264 or HEVC for the resolution and
    /// frame rate (8-bit, one connection). Applied when the profile is
    /// clicked; the user can change them afterwards.
    var codecPreference: TBDisplayCodecPreference = .automatic
    var parallelStreams: Bool = true
    var colorSpacePreference: TBVideoColorSpacePreference = .automatic
}

enum TBDisplayProfile: String, CaseIterable, Identifiable, Codable {
    case work5K
    case lowLatency
    case presentation

    var id: String { rawValue }

    var settings: TBDisplayProfileSettings {
        switch self {
        case .work5K:
            return TBDisplayProfileSettings(
                captureSource: .extendedDesktop,
                capturePreset: .native5k,
                matchRenderToStream: true,
                audioEnabled: nil,
                codecPreference: .uncompressedEnhanced,
                parallelStreams: true
            )
        case .lowLatency:
            return TBDisplayProfileSettings(
                captureSource: .desktopMirror,
                capturePreset: .smooth1440p60,
                matchRenderToStream: false,
                audioEnabled: nil
            )
        case .presentation:
            return TBDisplayProfileSettings(
                captureSource: .desktopMirror,
                capturePreset: .standard1440p,
                matchRenderToStream: false,
                audioEnabled: true
            )
        }
    }
}
