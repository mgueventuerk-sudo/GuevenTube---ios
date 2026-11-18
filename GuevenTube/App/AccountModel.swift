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

    func startSignIn() {
        task?.cancel()
        let flow = DeviceAuthFlow(oauth: env.oauth, profiles: InnerTubeProfileSource(service: env.innerTube), store: env.accounts)
        task = Task { [weak self] in
            await flow.run { s in Task { @MainActor in self?.state = s } }
            await self?.refresh()
        }
    }

    func cancelSignIn() { task?.cancel(); task = nil; state = .idle }

    func select(_ id: String?) async { _ = await env.accounts.setActive(id); await refresh() }
    func remove(_ id: String) async { await env.accounts.remove(id); await refresh() }
}
