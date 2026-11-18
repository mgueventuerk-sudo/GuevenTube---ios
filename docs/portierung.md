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
**Noch nicht portiert (Linux-testbar):** Einstellungen (`AppSettings`), Remote-Config-Paket, Verlauf/„Später ansehen“/Playlists-Modelle (Room → SwiftData), Kinder-Modus-Regeln, `link/` (Kopplung, gemeinsames Schauen), Auth (OAuth-Gerätecode).
**Nur auf dem Mac baubar (nicht angefasst):** SwiftUI-Oberfläche, AVPlayer-Anbindung (inkl. Bild+Ton-Zusammenführung), JavaScriptCore-Entschlüsselung (`ChallengeSolving`), Keychain (`SecretStoring`), Sperrbildschirm/Now-Playing, Hintergrund-Downloads, Biometrie.
