# GuevenTube iOS – Portierungsplan (iPhone, SwiftUI, Sideloading)

Quelle: Android-App `wavetv` (Gitea `muester1991/GuevenTube`, 2.5.1). Ziel: gleiche Funktionen, native iOS-Umsetzung.

## Grenzen
- .ipa-Build nur auf macOS (Xcode). Hier (Linux) kann Swift nicht kompiliert werden → Build und Tests laufen auf einem macOS-Runner (`.github/workflows/ios.yml`) oder einem Mac. Gitea/Woodpecker auf dem NAS hat keinen macOS-Runner.
- Unsigniertes IPA: Installation per AltStore/Sideloadly, Signatur läuft nach 7 Tagen (ohne bezahltes Apple-Konto) ab.

## Abbildung Android → iOS
| Android | iOS |
|---|---|
| Compose | SwiftUI |
| Media3/ExoPlayer, MediaSession | AVPlayer, MPNowPlayingInfoCenter, MPRemoteCommandCenter, Audio-Hintergrundmodus |
| Hilt | einfache Abhängigkeitsübergabe (Environment/Initializer) |
| Room | SwiftData (iOS 17) |
| OkHttp/Retrofit | URLSession |
| Rhino-Sandbox (Entschlüsselung) | JavaScriptCore |
| WorkManager-Downloads | URLSession Background-Konfiguration |
| BiometricPrompt-Sperre | LocalAuthentication |
| Verschlüsselte Speicherung | Keychain |

## Etappen
1. Gerüst + CI (dieser Stand).
2. InnerTube-Parser und Modelle (Feed, Suche, Watch-Next, Kapitel, Player, Konto) – **fertig**, 20 Tests grün auf Linux, u. a. mit den aufgezeichneten Such-Antworten der Android-App. 
   - **3a fertig:** InnerTube-Netzwerkdienst (Clients/Profile, Request-Bodies, Backoff bei 429/5xx, 401-Erneuerung, visitorData, Music-Fallback, Konfigurationsabruf) hinter `HTTPTransport`; 36 Tests grün auf Linux mit Fake-Transport.
3. StreamResolver (Client-Routen, Entschlüsselung via JavaScriptCore), Video-Player.
4. Musik: Warteschlange, Hintergrund, Sperrbildschirm-Steuerung.
5. Konto/Anmeldung, Mediathek, Verlauf, SponsorBlock.
6. Downloads, Autoplay, Geräte-Sperre, Einstellungen.
Jede Etappe: Tests gegen aufgezeichnete JSON-Antworten (aus Android-Testdaten übernehmbar).

## Entwicklungsumgebung (Linux, installiert am 18.11.2026)
- Swift 6.0.3 unter `/opt/swift` (`swift`, `swiftc` in `/usr/local/bin`). Kann nur Foundation-Code übersetzen, kein SwiftUI/AVFoundation/JavaScriptCore.
- Deshalb liegt die gesamte Logik (Parser, Modelle, Stream-Auswahl, Entschlüsselungs-Schnittstelle) im SwiftPM-Paket `Packages/GuevenCore` und wird hier mit `swift test --package-path Packages/GuevenCore` geprüft. Die App-Schicht (SwiftUI, AVPlayer, JavaScriptCore-Anbindung) wird nur auf macOS gebaut.

## Stand Etappe 3b (Resolver)
- `StreamResolver` (Wegwahl, zeitversetztes Hedging, Zwischenspeicher mit 5-min-Sicherheitsabstand, gemeinsame Auflösung, `rejectRoute`, `diagnose`), `RouteHealth` (Circuit Breaker), `FailureKind`, URL-Hilfen wie `android.net.Uri`. 67 Tests grün auf Linux.
- Austauschbare Schnittstellen für Dinge, die erst auf dem Mac laufen: `ChallengeSolving` (n-/Signatur-Entschlüsselung, später JavaScriptCore + yt-dlp-EJS-Solver), `PlayerScriptProviding` (Player-Skript, signatureTimestamp), `PoTokenProviding`, `PlayerEndpoint`.
- Nicht portiert (Labor/Android-spezifisch): SABR, NewPipe-Rückfall, signiertes Konfigurationspaket.
- Beim Portieren aufgefallen: In der Android-Version geht die Fehlerart `TECHNICAL` bei einer Gesamt-Zeitüberschreitung verloren (der `catch` in `resolveRoutes` ersetzt die Menge). In Swift behoben.

## Etappe 4a – Musik-Parser (fertig)
`MusicModels.swift`, `MusicParser.swift` (inkl. `MusicCover.hiRes`) aus `MusicParser.kt`/`MusicModels.kt`; 11 Tests, darunter zwei mit eingefrorenen WEB_REMIX-Antworten (`remix_next`, `remix_related`). Offen in Etappe 4: Warteschlangenlogik aus `MusicPlayback.kt` (Radio-Nachfüllen, Wiederholen, Mischen), `MusicSessionStore`, SponsorBlock, DeArrow, `DownloadQualityResolver`.

## Etappe 4b/4c – Wiedergabe-Warteschlange, Sitzung, SponsorBlock, Download-Qualität (fertig)
- `MusicQueueState` (reine Zustandsmaschine statt `MusicPlayback`; Player und Netz liefern/erhalten `MusicQueueEffect`), `MusicSessionStore` (Dateiformat, 7-Tage-Grenze, atomares Schreiben; Entprellen macht die App-Schicht).
- `SponsorBlockClient` (k-Anonymität über SHA-256-Präfix, eigene SHA-256-Implementierung gegen `sha256sum` geprüft, 30-min-Cache, Fallback auf veraltete Segmente, Höhepunkt). Abweichung von Android: Netzfehler werden bei `highlight` nicht als „kein Höhepunkt“ gemerkt.
- `DownloadQualityResolver` (H.264/AAC-MP4 bevorzugt).
- Offen in Etappe 4: DeArrow, Einstellungen/Feature-Flags, Persistenz (SwiftData), Abos, Kinder-Modus, Statistik.

## Etappe 4e – DeArrow, Transkript, Abo-Reihenfolge (fertig)
`DeArrowClient` (Abweichung: Netzfehler werden nicht gemerkt), `Transcript`/`TranscriptSummarizer` (Kurzfassung und Kapitel lokal), `SubscriptionSort`/`SubscriptionDatesStore`. **Bewusst nicht portiert:** `DashManifestGenerator` (AVPlayer spielt kein DASH; für getrennte Bild-/Tonströme braucht iOS einen eigenen Weg: `AVMutableComposition` oder lokal erzeugtes HLS – Entscheidung in der App-Schicht).

## Etappe 4g – Statistik und Feature-Flags (fertig)
`PlaybackStatsStore` (lokal, 300 Sitzungen), `FeatureFlags` (Standard → Nutzerwahl → Fern-Notschalter, nur ab-schaltend; Android-eigene Schalter entfallen).

## Stand: GuevenCore (161+8 Tests, alle unter Linux grün)
Fertig: JSON, Parser (Feed/Suche/Player/Watch-Next/Musik), InnerTube-Client, Player-Clients und -Routen, StreamResolver, SponsorBlock, DeArrow, Musik-Warteschlange und -Sitzung, Download-Qualität, Transkript/Kurzfassung, Abo-Reihenfolge, Statistik, Feature-Flags.
**Noch nicht portiert (Linux-testbar):** Einstellungen (`AppSettings`), Remote-Config-Paket, Verlauf/„Später ansehen“/Playlists-Modelle (Room → SwiftData), `link/` (Kopplung, gemeinsames Schauen).
**Nur auf dem Mac baubar (nicht angefasst):** SwiftUI-Oberfläche, AVPlayer-Anbindung (inkl. Bild+Ton-Zusammenführung), JavaScriptCore-Entschlüsselung (`ChallengeSolving`), Keychain (`SecretStoring`), Sperrbildschirm/Now-Playing, Hintergrund-Downloads, Biometrie.

## Etappe 5 – Anmeldung (fertig, 194 Tests)
`Auth.swift`: `AccountCredentials` (Tokens in Logs geschwärzt, alte Dateien lesbar), `OAuthClient` (Gerätecode, Polling, Erneuerung, Widerruf; Client-Kennung live aus dem TV-Skript mit Rückfall), `AuthTokenManager` (eine gemeinsame Erneuerung für parallele Aufrufer, „neu anmelden“ bei `invalid_grant`, alter Token bei Netzfehler solange gültig). Das Speichern der Konten (`AccountCredentialStore`) übernimmt auf dem iPhone die Keychain. Android-spezifisch entfällt der APK-Signaturcheck.

## Etappe 6 – Profil-PIN, Kindermodus, Abo-Import, Kanal-Einstellungen (fertig, 224 Tests)
`ProfileLock` (PBKDF2-HMAC-SHA256 mit 120 000 Runden, Sperrstufen 30 s bis 1 h, fail-closed bei unlesbarer/beschädigter PIN; unter Apple rechnet CommonCrypto, sonst reines Swift, gegen Python-Referenzwerte geprüft), `KidsTimeGuard` (Tageslimit, Schlafenszeit bis 7 Uhr, 30 Minuten PIN-Freigabe), `SubscriptionImport` (Takeout-CSV, NewPipe-JSON, nackte IDs), `ChannelPreferences`. Abweichung: PIN nur ASCII-Ziffern (Android ließ auch andere Unicode-Ziffern zu).

## Etappe 7 – Lokale Bibliothek (fertig, 235 Tests)
`LocalLibrary` (Actor, eine JSON-Datei statt Room): Weitersehen (ab 30 s, unter 95 %), Fortschrittsbalken, Fortsetz-Position, Abgleich mit gekoppeltem Gerät (nur neuere Einträge), „Später ansehen“ und Merklisten (eindeutige Namen, Löschen mit Einträgen), lokale Abos, Suchverlauf (30). Beschädigte Datei → leer starten. SwiftData ist damit nicht nötig.

## Etappe 8 – Einstellungen (fertig, 241 Tests)
`AppSettings` + `SettingsStore` (Actor, JSON-Datei mit denselben Schlüsseln wie Android-DataStore, nur Abweichungen vom Standard gespeichert, kaputte Werte → Standard, Tempo 0,25–3,0 begrenzt, Kinder-Limits begrenzt, Änderungs-Stream). Entfallen: Cronet, Fokusrahmen, Ambient, YouTube-App-Kopplung (TV/Android); Theme „DYNAMIC“ → System.

## Etappe 9 – Signiertes Fernpaket (fertig, 251 Tests)
`SignedConfig`, `SignedConfigVerifier`, `SignedConfigRepository` (Schema 1, 256 KB-Grenze, Rückspielschutz mit dauerhafter Versions-Untergrenze, gleiche Version nur mit identischem Inhalt, atomares Bündel aus Signatur+Paket, gespeicherte Kopie wird bei jedem Start neu geprüft, 6-h-Intervall, nur https). Die ECDSA-Prüfung steckt hinter `SignatureVerifying`; unter Linux getestet mit einem Hash-Stellvertreter, auf Apple prüft `CryptoKitSignatureVerifier` (P-256, DER) mit demselben Herausgeber-Schlüssel wie Android – **dieser Teil ist ungetestet bis zum ersten Mac-Lauf** (Test mit echter Signatur aus dem Android-Repo dann ergänzen).

## Etappe 10 – Kopplung mit dem Fernseher, Handy-Seite (fertig, 271 Tests)
`LinkProtocol` (Nachrichten, Base64url, Rahmen mit 256-KiB-Grenze, `LinkFrameCipher` mit Richtung‖Zähler-Nonce, `LinkChannel` mit reihenfolgetreuem Senden), `LinkMath` (SHA-256 mit Längenpräfix, HKDF, Fingerabdruck, Vergleichscode – **bitgleich zu Android, gegen Python-Referenzwerte geprüft**), `LinkClient` (Kopplung per QR-Token oder Vergleichscode, Wiederverbindung mit Identitäts- und Kopplungsschlüssel-Prüfung), `PairingGuard`, `LinkAuditLog`, `LinkStore` (Keychain, max. 8 Geräte). Die TV-Seite (`TvLinkServer`) und die Lounge-Kopplung mit der YouTube-App bleiben bei Android.
**Ungetestet bis zum ersten Mac-Lauf:** `CryptoKitLinkPrimitives` (P-256-ECDH als X-Koordinate, ECDSA-DER, AES-GCM Chiffretext‖Tag, SPKI-Schlüssel) – die Annahmen sind so gewählt, dass sie JCA entsprechen. Im Test steckt eine Gegenstelle (`TestTv`, Port von `LinkHandshake.server`) mit unsicheren Stellvertretern für die Mathematik. **Erster Mac-Test:** echte Kopplung iPhone ↔ Android-TV.
Noch offen im `link/`-Bereich: „Gemeinsam schauen“ (Watch-Together) und Netzwerk-Transport (Network.framework, Bonjour statt NSD) – App-Schicht.

## Etappe 11 – Vorschaubilder beim Spulen (fertig, 279 Tests)
`Storyboard` (Parser der Spezifikation, Stufenwahl, Bild-/Bogenberechnung inkl. Signatur) und `StoryboardRepository` (Cache 8, Fehlschläge 32 gemerkt; erst aus der Player-Antwort, dann leichte Player-Anfrage mit einem TV-Profil; Abbruch zählt nicht als Fehlschlag). Anbindung per Closures, damit ohne Netz testbar.

## Etappe 12 – Download-Logik (fertig, 291 Tests)
`DownloadStore` (JSON statt Room: neueste zuerst, wartende/laufende für den Neustart, IDs nie wiederverwendet), `DownloadRepository` (Massenauswahl und genaue Formatwahl, Wiederholen, Löschen samt Datei, `resumePending` nach App-Neustart; jeder Auftrag unabhängig), `DownloadPlanner` (Formatwahl wie `DownloadWorker.resolveFormats`, Fortschritt Ton 45 % / Bild bis 90 % / Zusammenfügen, Dateinamen ohne Pfadzeichen, VTT-URL, verständliche Fehlertexte). Abweichung: statt MediaStore-URI steht ein Dateiname im Download-Ordner (`fileLocation`).
**App-Schicht (Mac):** Hintergrund-`URLSession` (`DownloadScheduling`), Bild+Ton zusammenfügen mit `AVMutableComposition`/`AVAssetExportSession` (Passthrough; ersetzt `Remuxer`), Ablage in „Dateien“/Fotos.

## Etappe 13 – Gemeinsam schauen, Selbsttest, Sofortstart (fertig, 305 Tests)
`WatchTogether.plan` (Position mit 600 ms Vorlauf, Toleranz 2 s, Live öffnet nur, beim Puffern des TV nichts tun), `PlaybackSelfTest` (täglich, 1-KB-Probe mit Range und passendem User-Agent, Frühwarnung bei Bot-Prüfung/SABR, läuft nie doppelt, Ergebnis dauerhaft), `PlaybackPrefetcher` (wahrscheinlich vor spekulativ, 1 bzw. 2 Plätze mit Verdrängung, 10-min-Wiederholsperre, nur WLAN für spekulative, 20-s-Zeitlimit). Medien vorladen (`MediaPreloader`) bleibt App-Schicht (`afterResolved`-Haken).
**Damit ist die Linux-testbare Logik vollständig portiert.** Offen sind nur noch App-Schicht und Mac-Build.

## Etappe 14 – Player-Skript und Profil-Register (fertig, 320 Tests)
`PlayerScriptRepository` (der bisher fehlende Produktivteil von `PlayerScriptProviding`: Player-ID aus `iframe_api` mit 1-h-Cache, `base.js` im Speicher und auf der Platte, nur die zwei neuesten Versionen, ID-Format geprüft gegen Pfadtricks, `signatureTimestamp`, parallele Aufrufe laden einmal) und `PlayerClientRegistry` (der Produktivteil von `ClientProfileProviding`: eigene URL vor signiertem Paket vor eingebauten Profilen, zuletzt gültige Datei als Rückfall, ungültige Dateien werden nie gespeichert).

## Etappe 15 – Entschlüssler (App-Schicht, 332 Tests)
`EJSChallengeSolver` (Port von `SandboxChallengeSolver.kt`, plattformunabhängig, 12 Tests mit Fake-Engine unter Linux): ein Aufruf zur Zeit, LRU-Zwischenspeicher 512 mit Ablage `solutions.tsv` (nur der aktuelle Player), analysierte Player-Datei wird je Player-ID auf der Platte abgelegt (`preprocessed-<id>.js`, nur die neuesten 2; ID-Format geprüft) – die teure Analyse läuft damit nur einmal je Player-Version. `JavaScriptCoreEngine` (nur Apple, **ungetestet bis zum ersten Mac-Lauf**): eigener `JSContext`, Ausführung auf Thread mit 64 MB Stack, Zeitablauf verwirft die Engine. `GuevenTube/App/Services/SolverFactory.swift` verdrahtet beides; die EJS-Skripte (0.8.0) liegen bitgleich zu Android in `GuevenTube/Resources/solver`.
**Risiko (geraten):** JavaScriptCore läuft in normalen Apps ohne JIT. Android/QuickJS (ebenfalls Interpreter) brauchte für die Analyse über 10 Minuten, V8 1,4 s. Misst der erste Mac-Lauf Minuten statt Sekunden, ist `WKWebView` (hat JIT) der Ausweichweg; dafür genügt eine zweite `JSEngine`-Implementierung, der Solver bleibt unverändert. Nachteil: WKWebView-JavaScript wird im Hintergrund gedrosselt.
