/// Kennungen, die nicht im Quellcode stehen. Diese Datei ist absichtlich leer eingecheckt.
/// Der Build füllt sie aus Umgebungsvariablen: `scripts/inject-secrets.sh` (lokal und in GitHub Actions).
/// Die geänderte Datei nie committen (lokal: `git update-index --assume-unchanged <Datei>`).
public enum BuildSecrets {
    /// OAuth-Client der YouTube-TV-Web-App (nur Rückfall, wenn die Live-Suche im TV-Skript scheitert).
    public static let ytTvClientId = ""
    public static let ytTvClientSecret = ""
    /// API-Schlüssel des YouTube-Web-Clients für den BotGuard-Dienst (PO-Token).
    public static let ytWebApiKey = ""
}
