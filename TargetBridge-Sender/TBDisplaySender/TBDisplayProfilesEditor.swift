import SwiftUI

/// Settings section for the Display profiles: one-click combinations of
/// stream profile, video compression and parallel connections. Profiles can be
/// renamed, changed, reordered, removed and added; "Restore defaults" brings
/// back the built-in ones.
struct TBDisplayProfilesEditor: View {
    @ObservedObject var service: TBDisplaySenderService
    @State private var confirmingRestore = false

    private var language: TBDisplaySenderLanguage { service.language }

    private func text(_ key: String) -> String {
        TBDisplaySenderL10n.text(key, language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("sender.display_profiles.editor_hint"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if service.displayProfiles.isEmpty {
                Text(text("sender.display_profiles.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(service.displayProfiles.enumerated()), id: \.element.id) { index, profile in
                profileCard(profile, index: index)
            }

            HStack(spacing: 10) {
                Button {
                    service.addDisplayProfile()
                } label: {
                    Label(text("sender.display_profiles.add"), systemImage: "plus")
                }
                Spacer()
                Button(text("sender.display_profiles.restore")) {
                    confirmingRestore = true
                }
            }
        }
        .confirmationDialog(
            text("sender.display_profiles.restore_confirm_title"),
            isPresented: $confirmingRestore
        ) {
            Button(text("sender.display_profiles.restore"), role: .destructive) {
                service.restoreDefaultDisplayProfiles()
            }
            Button(text("sender.display_profiles.cancel"), role: .cancel) {}
        } message: {
            Text(text("sender.display_profiles.restore_confirm_text"))
        }
    }

    private func profileCard(_ profile: TBDisplayProfile, index: Int) -> some View {
        SurfaceSubcard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField(
                        profile.title(language),
                        text: binding(profile.id, \.name)
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)

                    Button {
                        service.moveDisplayProfile(id: profile.id, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .help(text("sender.display_profiles.move_up"))
                    .disabled(index == 0)

                    Button {
                        service.moveDisplayProfile(id: profile.id, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .help(text("sender.display_profiles.move_down"))
                    .disabled(index == service.displayProfiles.count - 1)

                    Button(role: .destructive) {
                        service.removeDisplayProfile(id: profile.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help(text("sender.display_profiles.remove"))
                }

                Picker(TBDisplaySenderL10n.streamProfile(language), selection: presetBinding(profile.id)) {
                    ForEach(TBDisplayCapturePreset.allCases, id: \.self) { preset in
                        Text("\(preset.title(language)) · \(preset.description)").tag(preset)
                    }
                }
                .pickerStyle(.menu)

                Picker(TBDisplaySenderL10n.videoCompression(language), selection: codecBinding(profile.id)) {
                    ForEach(profile.capturePreset.allowedCodecPreferences) { preference in
                        Text(TBDisplaySenderL10n.codecPreferenceTitle(preference, language: language))
                            .tag(preference)
                    }
                }
                .pickerStyle(.menu)

                if profile.effectiveCodecPreference.usesParallelStreams {
                    Toggle(TBDisplaySenderL10n.parallelStreams(language), isOn: binding(profile.id, \.parallelStreams))
                        .disabled(profile.effectiveCodecPreference.needsParallelStreams)
                        .help(TBDisplaySenderL10n.parallelStreamsHint(language))
                }
            }
        }
    }

    // MARK: Bindings into service.displayProfiles

    private func binding<Value>(_ id: String,
                                _ keyPath: WritableKeyPath<TBDisplayProfile, Value>) -> Binding<Value> {
        Binding(
            get: {
                let profile = service.displayProfiles.first(where: { $0.id == id })
                    ?? TBDisplayProfile.defaults[0]
                return profile[keyPath: keyPath]
            },
            set: { newValue in
                guard var profile = service.displayProfiles.first(where: { $0.id == id }) else { return }
                profile[keyPath: keyPath] = newValue
                service.updateDisplayProfile(profile)
            }
        )
    }

    /// Changing the stream profile keeps the compression only where it is
    /// allowed; otherwise the stream profile's own mode is used.
    private func presetBinding(_ id: String) -> Binding<TBDisplayCapturePreset> {
        Binding(
            get: { service.displayProfiles.first(where: { $0.id == id })?.capturePreset ?? .standard1440p },
            set: { preset in
                guard var profile = service.displayProfiles.first(where: { $0.id == id }) else { return }
                profile.capturePreset = preset
                profile.codecPreference = profile.effectiveCodecPreference
                service.updateDisplayProfile(profile)
            }
        )
    }

    private func codecBinding(_ id: String) -> Binding<TBDisplayCodecPreference> {
        Binding(
            get: { service.displayProfiles.first(where: { $0.id == id })?.effectiveCodecPreference ?? .automatic },
            set: { preference in
                guard var profile = service.displayProfiles.first(where: { $0.id == id }) else { return }
                profile.codecPreference = preference
                if preference.needsParallelStreams { profile.parallelStreams = true }
                service.updateDisplayProfile(profile)
            }
        )
    }
}
