import SwiftUI
import GuevenCore

struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    var body: some View {
        Form {
            Section("Wiedergabe") {
                Picker("Höchste Auflösung", selection: binding(\.maxResolution)) {
                    Text("Automatisch").tag(ResolutionTier?.none)
                    ForEach(ResolutionTier.allCases.filter { $0.height <= 1080 }, id: \.self) { Text($0.label).tag(ResolutionTier?.some($0)) }
                }
                Toggle("Autoplay", isOn: binding(\.autoplay))
                Toggle("Hintergrundwiedergabe", isOn: binding(\.backgroundPlayback))
                Picker("Standard-Tempo", selection: binding(\.defaultPlaybackSpeed)) {
                    ForEach(SettingsStore.playbackSpeeds, id: \.self) { Text(String(format: "%.2g×", $0)).tag($0) }
                }
            }
            Section("SponsorBlock") {
                Toggle("Aktiv", isOn: binding(\.sponsorBlockEnabled))
                if model.settings.sponsorBlockEnabled {
                    ForEach(SponsorCategory.allCases, id: \.self) { c in
                        Picker(c.displayName, selection: modeBinding(c)) {
                            ForEach(SkipMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                }
            }
            Section("Titel") { Toggle("DeArrow (bessere Titel und Vorschaubilder)", isOn: binding(\.deArrowEnabled)) }
        }
        .navigationTitle("Einstellungen")
        .task { await model.load() }
    }

    private func binding<T: Sendable>(_ path: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        let p = UncheckedKeyPath(path)
        return Binding(get: { model.settings[keyPath: path] }, set: { v in model.change { $0[keyPath: p.value] = v } })
    }

    private func modeBinding(_ c: SponsorCategory) -> Binding<SkipMode> {
        Binding(get: { model.settings.skipMode(c) }, set: { v in model.change { $0.skipModes[c] = v } })
    }
}

/// `WritableKeyPath` ist nicht `Sendable`; der Pfad ist unveränderlich und wird nur gelesen.
private struct UncheckedKeyPath<Root, Value>: @unchecked Sendable {
    let value: WritableKeyPath<Root, Value>
    init(_ v: WritableKeyPath<Root, Value>) { value = v }
}
