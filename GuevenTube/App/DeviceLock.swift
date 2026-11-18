import LocalAuthentication

/// Optionale Sperre für Konto und Einstellungen (Port von `DeviceLock.kt`): Face ID/Touch ID oder Geräte-Code über das System.
/// Ohne eingerichteten Geräte-Code gibt es nichts zu prüfen – dann wird durchgelassen. Apple-only, ungetestet.
enum DeviceLock {
    static let defaultsKey = "security.deviceLock"

    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// `true` = bestätigt (oder nichts zu bestätigen).
    @MainActor
    static func confirm(_ reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
