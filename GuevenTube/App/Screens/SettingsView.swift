import SwiftUI
import GuevenCore

struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    @EnvironmentObject private var kids: KidsModel
    @State private var kidsUnlocked = false
    @State private var pinInput = ""
    @State private var newPin = ""
    @State private var kidsMessage: String?

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
            kidsSection
            Section("Titel") { Toggle("DeArrow (bessere Titel und Vorschaubilder)", isOn: binding(\.deArrowEnabled)) }
        }
        .navigationTitle("Einstellungen")
        .task { await model.load() }
    }

    /// Änderungen am Kindermodus sind PIN-geschützt, sobald der Modus an ist und eine PIN existiert.
    private var kidsLocked: Bool { model.settings.kidsMode && kids.hasPin && !kidsUnlocked }

    @ViewBuilder private var kidsSection: some View {
        Section {
            if kidsLocked {
                SecureField("PIN zum Ändern", text: $pinInput).keyboardType(.numberPad)
                Button("Entsperren") {
                    Task {
                        kidsMessage = await kids.verify(pin: pinInput); pinInput = ""
                        kidsUnlocked = kidsMessage == nil
                    }
                }.disabled(pinInput.count < 4)
            } else {
                if !kids.hasPin {
                    SecureField("Neue PIN (4–8 Ziffern)", text: $newPin).keyboardType(.numberPad)
                    Button("PIN setzen") { Task { kidsMessage = await kids.setPin(newPin); newPin = "" } }.disabled(newPin.count < 4)
                }
                // Ohne PIN lässt sich der Modus nicht einschalten – sonst könnte ihn jeder sofort wieder ausschalten.
                Toggle("Kindermodus", isOn: binding(\.kidsMode)).disabled(!kids.hasPin && !model.settings.kidsMode)
                if model.settings.kidsMode {
                    Picker("Tageslimit", selection: binding(\.kidsDailyLimitMinutes)) {
                        Text("Aus").tag(0)
                        ForEach([30, 60, 90, 120, 180], id: \.self) { Text("\($0) Min.").tag($0) }
                    }
                    Picker("Schlafenszeit ab", selection: binding(\.kidsBedtimeHour)) {
                        Text("Aus").tag(0)
                        ForEach(18...23, id: \.self) { Text("\($0) Uhr").tag($0) }
                    }
                    Text("Heute genutzt: \(kids.usedMinutes) Min.").font(.footnote).foregroundStyle(.secondary)
                }
                if kids.hasPin && !model.settings.kidsMode {
                    Button("PIN entfernen", role: .destructive) { Task { await kids.removePin() } }
                }
            }
            if let kidsMessage { Text(kidsMessage).foregroundStyle(.red).font(.footnote) }
        } header: { Text("Kindermodus") }
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
