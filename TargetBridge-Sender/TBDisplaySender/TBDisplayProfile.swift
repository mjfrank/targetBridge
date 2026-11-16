import Foundation

/// A Display profile: a one-click combination of a stream profile, a video
/// compression and the parallel-connections setting. The list is edited in
/// Settings (add, edit, remove, restore defaults) and shared by all sessions.
struct TBDisplayProfile: Codable, Identifiable, Equatable {
    /// Stable identifier. The built-in profiles use their old names
    /// ("work5K", "lowLatency", "presentation"), so a receiver's remembered
    /// choice from earlier versions still matches.
    var id: String
    /// Set for the built-in profiles: their name is translated until it is
    /// changed.
    var builtIn: String?
    /// The user's name; empty for an unrenamed built-in profile.
    var name: String
    var capturePreset: TBDisplayCapturePreset
    var codecPreference: TBDisplayCodecPreference
    var parallelStreams: Bool

    init(id: String = UUID().uuidString,
         builtIn: String? = nil,
         name: String,
         capturePreset: TBDisplayCapturePreset,
         codecPreference: TBDisplayCodecPreference = .automatic,
         parallelStreams: Bool = true) {
        self.id = id
        self.builtIn = builtIn
        self.name = name
        self.capturePreset = capturePreset
        self.codecPreference = codecPreference
        self.parallelStreams = parallelStreams
    }

    // Stored with raw values; unknown ones (a newer or older version) fall
    // back instead of dropping the whole list.
    private enum CodingKeys: String, CodingKey {
        case id, builtIn, name, capturePreset, codecPreference, parallelStreams
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        builtIn = try container.decodeIfPresent(String.self, forKey: .builtIn)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        capturePreset = (try container.decodeIfPresent(String.self, forKey: .capturePreset))
            .flatMap(TBDisplayCapturePreset.init(rawValue:)) ?? .standard1440p
        codecPreference = (try container.decodeIfPresent(String.self, forKey: .codecPreference))
            .flatMap(TBDisplayCodecPreference.init(rawValue:)) ?? .automatic
        parallelStreams = try container.decodeIfPresent(Bool.self, forKey: .parallelStreams) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(builtIn, forKey: .builtIn)
        try container.encode(name, forKey: .name)
        try container.encode(capturePreset.rawValue, forKey: .capturePreset)
        try container.encode(codecPreference.rawValue, forKey: .codecPreference)
        try container.encode(parallelStreams, forKey: .parallelStreams)
    }

    /// The compression this profile applies: its own choice when the stream
    /// profile allows it, otherwise the stream profile's own mode.
    var effectiveCodecPreference: TBDisplayCodecPreference {
        if capturePreset.allowedCodecPreferences.contains(codecPreference) { return codecPreference }
        return capturePreset.defaultCodecPreference ?? .automatic
    }

    /// Parallel connections only matter for the uncompressed modes; the
    /// 10-bit changed-rows modes need them.
    var effectiveParallelStreams: Bool {
        parallelStreams || effectiveCodecPreference.needsParallelStreams
    }

    func title(_ language: TBDisplaySenderLanguage) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let builtIn { return TBDisplaySenderL10n.text("sender.display_profiles.\(Self.builtInKeys[builtIn] ?? builtIn)", language) }
        return TBDisplaySenderL10n.text("sender.display_profiles.untitled", language)
    }

    /// Built-in profile id -> translation key suffix.
    static let builtInKeys = [
        "work5K": "work_5k",
        "lowLatency": "low_latency",
        "presentation": "presentation"
    ]

    /// What "Restore defaults" brings back.
    static let defaults: [TBDisplayProfile] = [
        TBDisplayProfile(id: "work5K", builtIn: "work5K", name: "",
                         capturePreset: .native5k, codecPreference: .automatic, parallelStreams: true),
        TBDisplayProfile(id: "lowLatency", builtIn: "lowLatency", name: "",
                         capturePreset: .smooth1440p60, codecPreference: .automatic, parallelStreams: true),
        TBDisplayProfile(id: "presentation", builtIn: "presentation", name: "",
                         capturePreset: .standard1440p, codecPreference: .automatic, parallelStreams: true)
    ]

    /// Loads the saved list; nil when nothing (valid) was saved yet.
    static func decodeList(_ data: Data?) -> [TBDisplayProfile]? {
        guard let data, let list = try? JSONDecoder().decode([TBDisplayProfile].self, from: data) else { return nil }
        return list
    }

    static func encodeList(_ list: [TBDisplayProfile]) -> Data? {
        try? JSONEncoder().encode(list)
    }
}
