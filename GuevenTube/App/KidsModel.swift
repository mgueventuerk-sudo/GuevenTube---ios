import SwiftUI
import GuevenCore

/// Kindermodus: zählt die Wiedergabezeit, sperrt bei Tageslimit/Schlafenszeit und verwaltet die Profil-PIN.
@MainActor
final class KidsModel: ObservableObject {
    @Published private(set) var block: KidsBlock?
    @Published private(set) var hasPin = false
    @Published private(set) var usedMinutes: Int64 = 0

    private let env = AppEnvironment.shared
    private var loop: Task<Void, Never>?

    /// Startet den Takt (alle 15 s). Bei Sperre wird die Wiedergabe angehalten.
    func start(player: PlayerManager) {
        guard loop == nil else { return }
        loop = Task { [weak self, weak player] in
            while !Task.isCancelled {
                guard let self, let player else { return }
                await self.tick(player: player)
                try? await Task.sleep(nanoseconds: UInt64(KidsTimeGuard.tickMs) * 1_000_000)
            }
        }
    }

    func tick(player: PlayerManager) async {
        let s = await env.settings.current()
        let kids = KidsSettings(kidsMode: s.kidsMode, kidsBedtimeHour: s.kidsBedtimeHour, kidsDailyLimitMinutes: s.kidsDailyLimitMinutes)
        let result = await env.kidsGuard.tick(settings: kids, playing: player.state == .playing)
        usedMinutes = await env.kidsGuard.usedMinutesToday()
        block = result
        if result != nil { player.pause() }
    }

    func refreshPin() async { hasPin = await env.profileLock.hasPin() }

    /// Entsperrt für 30 Minuten; Rückgabe ist eine Fehlermeldung oder `nil`.
    func unlock(pin: String) async -> String? {
        let error = await env.kidsGuard.unlock(pin: pin)
        if error == nil { block = nil }
        return error
    }

    func verify(pin: String) async -> String? {
        switch await env.profileLock.verify(pin) {
        case .ok: return nil
        case .wrong: return "Falsche PIN."
        case .locked(let s): return "Zu viele Versuche – bitte \(s) s warten."
        }
    }

    func setPin(_ pin: String) async -> String? {
        do { try await env.profileLock.setPin(pin) } catch { return "Die PIN braucht 4 bis 8 Ziffern." }
        await refreshPin()
        return nil
    }

    func removePin() async { await env.profileLock.removePin(); await refreshPin() }
}
