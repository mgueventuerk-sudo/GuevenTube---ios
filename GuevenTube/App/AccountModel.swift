import SwiftUI
import GuevenCore

/// Konten und Geräteanmeldung. Apple-only, ungetestet (die Ablauflogik steckt in `DeviceAuthFlow` und ist getestet).
@MainActor
final class AccountModel: ObservableObject {
    @Published private(set) var state: DeviceAuthState = .idle
    @Published private(set) var accounts: [AccountCredentials] = []
    @Published private(set) var activeId: String?

    private let env = AppEnvironment.shared
    private var task: Task<Void, Never>?

    func refresh() async {
        accounts = await env.accounts.allAccounts()
        activeId = await env.accounts.activeAccountId()
    }

    private static let pendingKey = "pendingDeviceAuth"
    private var generation = 0

    nonisolated private static func savePending(_ p: PendingDeviceAuth?) {
        if let p, let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: pendingKey) }
        else { UserDefaults.standard.removeObject(forKey: pendingKey) }
    }

    private static func loadPending() -> PendingDeviceAuth? {
        UserDefaults.standard.data(forKey: pendingKey).flatMap { try? JSONDecoder().decode(PendingDeviceAuth.self, from: $0) }
    }

    func startSignIn(resume: PendingDeviceAuth? = nil) {
        task?.cancel()
        generation += 1
        let mine = generation
        let flow = DeviceAuthFlow(oauth: env.oauth, profiles: InnerTubeProfileSource(service: env.innerTube), store: env.accounts)
        task = Task { [weak self] in
            await flow.run(resume: resume, onPending: { Self.savePending($0) }, report: { s in Task { @MainActor in self?.state = s } })
            await self?.refresh()
            if let self, self.generation == mine { self.task = nil }
        }
    }

    /// Hat iOS die App während der Bestätigung im Browser beendet, läuft die Anmeldung mit dem gespeicherten Code weiter.
    func resumeIfPending() {
        guard task == nil, let p = Self.loadPending() else { return }
        guard p.expiresAtMs > Int64(Date().timeIntervalSince1970 * 1000) else { Self.savePending(nil); return }
        startSignIn(resume: p)
    }

    func cancelSignIn() { task?.cancel(); task = nil; Self.savePending(nil); state = .idle }

    func select(_ id: String?) async { _ = await env.accounts.setActive(id); await refresh() }
    func remove(_ id: String) async { await env.accounts.remove(id); await refresh() }
}
