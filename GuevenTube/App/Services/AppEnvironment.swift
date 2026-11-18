import Foundation
import GuevenCore

/// Kompositionswurzel: baut alle Dienste einmal auf. Apple-only (Keychain, JavaScriptCore), bis zum ersten Mac-Lauf ungetestet.
final class AppEnvironment: @unchecked Sendable {
    let transport: HTTPTransport
    let secrets: SecretStoring
    let accounts: KeychainAccountStore
    let auth: AuthTokenManager
    let oauth: OAuthClient
    let config: InnerTubeConfigProvider
    let innerTube: InnerTubeService
    let playerScripts: PlayerScriptRepository
    let solver: EJSChallengeSolver
    let registry: PlayerClientRegistry
    let health: RouteHealth
    let resolver: StreamResolver
    let values: StringValueStore
    let settings: SettingsStore
    let sponsorBlock: SponsorBlockClient

    static let shared = AppEnvironment()

    private init() {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let caches = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        func dir(_ base: URL, _ name: String) -> URL {
            let u = base.appendingPathComponent(name, isDirectory: true)
            try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }

        let transport = URLSessionTransport()
        let keychain = KeychainSecretBackend()
        let secrets = BackendSecretStore(backend: keychain)
        let values = DefaultsStringStore()
        let accounts = KeychainAccountStore(backend: keychain)
        let config = InnerTubeConfigProvider(transport: transport)
        let oauth = OAuthClient(transport: transport, tvScriptUrl: { await config.config().tvScriptUrl })
        let auth = AuthTokenManager(store: accounts, oauth: oauth)
        let innerTube = InnerTubeService(transport: transport, config: config, auth: auth, secrets: secrets)

        // Player-Skripte (base.js) liegen in Caches: gehen sie verloren, werden sie neu geladen.
        let scripts = PlayerScriptRepository(transport: transport, directory: dir(caches, "player-scripts"))
        // Die analysierten Skripte sind teuer (JavaScriptCore ohne JIT) und liegen deshalb in Application Support.
        let solver = SolverFactory.make(playerScripts: scripts, directory: dir(support, "solver"))
        let registry = PlayerClientRegistry(
            transport: transport,
            cacheFile: dir(support, "clients").appendingPathComponent("profiles.json"),
            profilesUrl: { values.string("clients.profilesUrl") },
            signedConfig: { nil })
        let health = RouteHealth(store: DefaultsPreferredRouteStore(),
                                 clock: { Int64(ProcessInfo.processInfo.systemUptime * 1000) })
        let resolver = StreamResolver(endpoint: innerTube, registry: registry, solver: solver, scripts: scripts, health: health)

        let settings = SettingsStore(file: dir(support, "settings").appendingPathComponent("settings.json"))
        let sponsorBlock = SponsorBlockClient(transport: transport)

        self.settings = settings; self.sponsorBlock = sponsorBlock
        self.transport = transport; self.secrets = secrets; self.accounts = accounts; self.auth = auth; self.oauth = oauth
        self.config = config; self.innerTube = innerTube; self.playerScripts = scripts; self.solver = solver
        self.registry = registry; self.health = health; self.resolver = resolver; self.values = values
    }
}
