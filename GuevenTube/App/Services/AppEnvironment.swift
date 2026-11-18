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
    let poTokens: PoTokenMinter
    let values: StringValueStore
    let settings: SettingsStore
    let library: LocalLibrary
    let downloadStore: DownloadStore
    let downloadManager: DownloadManager
    let downloads: DownloadRepository
    let sponsorBlock: SponsorBlockClient
    let profileLock: ProfileLock
    let deArrow: DeArrowClient
    let kidsGuard: KidsTimeGuard
    let link: LinkStore

    static let shared = AppEnvironment()

    private init() {
        FreshInstall.wipeKeychainIfNeeded()
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
        // PO-Token (BotGuard im unsichtbaren WKWebView): Safari spielt im selben Netz ab, die App ohne diesen Schlüssel nicht.
        let poTokens = PoTokenMinter(transport: transport)
        let resolver = StreamResolver(endpoint: innerTube, registry: registry, solver: solver, scripts: scripts,
                                      poTokens: poTokens, health: health, autoPoToken: true, alwaysPoToken: true)

        let settings = SettingsStore(file: dir(support, "settings").appendingPathComponent("settings.json"))
        let sponsorBlock = SponsorBlockClient(transport: transport)

        let downloadStore = DownloadStore(file: dir(support, "downloads").appendingPathComponent("downloads.json"))
        let downloadManager = DownloadManager(store: downloadStore, resolver: resolver)
        let downloads = DownloadRepository(store: downloadStore, scheduler: downloadManager, removeFile: { name in
            try? FileManager.default.removeItem(at: DownloadManager.downloadsDirectory.appendingPathComponent(name))
        })
        self.downloadStore = downloadStore; self.downloadManager = downloadManager; self.downloads = downloads
        let library = LocalLibrary(file: dir(support, "library").appendingPathComponent("library.json"))
        self.library = library
        let profileLock = ProfileLock(store: BackendProfileLockStore(backend: keychain, plain: values))
        self.profileLock = profileLock
        self.deArrow = DeArrowClient(transport: transport)
        self.link = LinkStore(secrets: secrets, deviceModel: "iPhone")
        self.kidsGuard = KidsTimeGuard(usage: DefaultsKidsUsageStore(), profileLock: profileLock)
        self.settings = settings; self.sponsorBlock = sponsorBlock
        self.transport = transport; self.secrets = secrets; self.accounts = accounts; self.auth = auth; self.oauth = oauth
        self.config = config; self.innerTube = innerTube; self.playerScripts = scripts; self.solver = solver
        self.registry = registry; self.health = health; self.resolver = resolver; self.poTokens = poTokens; self.values = values
    }
}
