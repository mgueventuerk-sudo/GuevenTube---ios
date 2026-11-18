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
2. InnerTube-Client (Parser/Modelle), Feed, Suche.
3. StreamResolver (Client-Routen, Entschlüsselung via JavaScriptCore), Video-Player.
4. Musik: Warteschlange, Hintergrund, Sperrbildschirm-Steuerung.
5. Konto/Anmeldung, Mediathek, Verlauf, SponsorBlock.
6. Downloads, Autoplay, Geräte-Sperre, Einstellungen.
Jede Etappe: Tests gegen aufgezeichnete JSON-Antworten (aus Android-Testdaten übernehmbar).

## Entwicklungsumgebung (Linux, installiert am 18.11.2026)
- Swift 6.0.3 unter `/opt/swift` (`swift`, `swiftc` in `/usr/local/bin`). Kann nur Foundation-Code übersetzen, kein SwiftUI/AVFoundation/JavaScriptCore.
- Deshalb liegt die gesamte Logik (Parser, Modelle, Stream-Auswahl, Entschlüsselungs-Schnittstelle) im SwiftPM-Paket `Packages/GuevenCore` und wird hier mit `swift test --package-path Packages/GuevenCore` geprüft. Die App-Schicht (SwiftUI, AVPlayer, JavaScriptCore-Anbindung) wird nur auf macOS gebaut.
