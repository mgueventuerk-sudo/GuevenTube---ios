import SwiftUI
import UIKit

/// Farben und Maße der Android-App (`mobile/MobileTheme.kt`), als hell/dunkel umschaltende iOS-Farben.
/// Alle Bildschirme beziehen ihre Farben von hier, damit die App überall gleich aussieht.
enum GT {
    static let accent = Color(light: 0xCC0029, dark: 0xFF0033)
    static let background = Color(light: 0xFFFFFF, dark: 0x0F0F0F)
    /// Chips, Karten, Platzhalter (surfaceContainerHigh der Android-App).
    static let surface = Color(light: 0xF2F2F2, dark: 0x272727)
    static let surfaceHigh = Color(light: 0xE5E5E5, dark: 0x303030)
    static let secondaryText = Color(light: 0x606060, dark: 0xAAAAAA)
    static let live = Color(light: 0xCC0000, dark: 0xCC0000)
    static let success = Color(light: 0x34C759, dark: 0x34C759)

    enum Metric {
        /// Mindestgröße tippbarer Elemente (Apple Human Interface Guidelines).
        static let touch: CGFloat = 44
        static let cornerCard: CGFloat = 12
        static let cornerThumb: CGFloat = 10
        static let page: CGFloat = 16
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { traits in UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light) })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
