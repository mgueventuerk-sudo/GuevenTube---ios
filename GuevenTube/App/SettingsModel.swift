import SwiftUI
import GuevenCore

/// Spiegel der Einstellungen für die Oberfläche; jede Änderung geht durch `SettingsStore.update` (dort geprüft und gespeichert).
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var settings = AppSettings()
    private let store = AppEnvironment.shared.settings

    func load() async { settings = await store.current() }

    func change(_ block: @escaping @Sendable (inout AppSettings) -> Void) {
        Task { await store.update(block); settings = await store.current() }
    }
}
