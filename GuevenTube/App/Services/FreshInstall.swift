import Foundation
import Security
import UIKit

/// Der iOS-Schlüsselbund überlebt das Löschen der App (Anmeldung, Besucher-Kennung bleiben liegen), alles andere
/// (Einstellungen, Dateien, UserDefaults) nicht. Damit eine Neuinstallation wirklich bei null beginnt, löscht die App
/// beim ersten Start nach einer Installation ihre Schlüsselbund-Einträge. Erkennungszeichen: Ein Eintrag in den
/// UserDefaults, der mit der App verschwindet.
enum FreshInstall {
    private static let marker = "install.marker.v1"

    static func wipeKeychainIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: marker) == nil else { return }
        // Vor dem ersten Entsperren nach einem Neustart (z. B. Start im Hintergrund) sind die UserDefaults unlesbar und der Marker
        // sähe „fehlend“ aus: dann würde die Anmeldung einer bestehenden Installation fälschlich gelöscht. Dann lieber nichts tun.
        guard Thread.isMainThread, UIApplication.shared.isProtectedDataAvailable else { return }
        // Ohne Dienstangabe: alle generischen Passwörter dieser App (Konten, Besucher-Kennung, Profilsperre, Kopplung).
        SecItemDelete([kSecClass as String: kSecClassGenericPassword] as CFDictionary)
        defaults.set(UUID().uuidString, forKey: marker)
    }
}
