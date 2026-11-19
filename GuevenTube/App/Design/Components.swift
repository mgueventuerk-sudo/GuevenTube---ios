import SwiftUI
import GuevenCore

// MARK: Listen und Bildschirme

extension View {
    /// Einheitliche Liste: ohne Trennlinien-Rahmen, Hintergrund in der App-Farbe.
    func gtList() -> some View {
        listStyle(.plain).scrollContentBackground(.hidden).background(GT.background)
    }

    /// Einheitliches „Fertig“ für Dialoge, die nur geschlossen werden: immer rechts oben (Apple-Konvention).
    /// „Abbrechen“ (verwirft etwas) steht dagegen immer links.
    func doneToolbar(_ dismiss: @escaping () -> Void) -> some View {
        toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fertig", action: dismiss).fontWeight(.semibold) } }
    }
}

// MARK: Chips (Aktionsleiste im Player, Filter)

/// Runde Schaltfläche mit Symbol und Text, immer in derselben Höhe und Reihenfolge-Optik.
struct ChipLabel: View {
    let title: String
    let systemImage: String
    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(GT.surface, in: Capsule())
            .foregroundStyle(.primary)
            .contentShape(Capsule())
    }
}

struct ChipButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { ChipLabel(title: title, systemImage: systemImage) }
            .buttonStyle(.plain)
            .frame(minHeight: GT.Metric.touch)
    }
}

// MARK: Vorschaubild

struct VideoThumbnail: View {
    let url: String
    let item: VideoItem
    var corner: CGFloat = GT.Metric.cornerThumb

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                AsyncImage(url: URL(string: url)) { phase in
                    switch phase {
                    case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                    default: GT.surface
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(alignment: .bottomTrailing) { badge.padding(6) }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var badge: some View {
        if item.isLive {
            Text("LIVE").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 3)
                .background(GT.live, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
        } else if let d = item.durationSeconds {
            Text(VideoRow.format(d)).font(.caption2.weight(.semibold)).monospacedDigit().padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
        }
    }
}

// MARK: Fehlertexte

enum GTError {
    /// Deutsche, handlungsorientierte Meldung statt `String(describing:)` (kein englischer Fehlertext im Bildschirm).
    static func text(_ error: Error) -> String {
        if error is CancellationError { return "Abgebrochen." }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost: return "Keine Internetverbindung. Prüfe WLAN oder Mobilfunk und ziehe zum Neuladen nach unten."
            case .timedOut: return "Zeitüberschreitung. Ziehe zum Neuladen nach unten."
            default: return "Netzwerkfehler (\(url.code.rawValue)). Ziehe zum Neuladen nach unten."
            }
        }
        if let e = error as? PlaybackUnavailableError { return e.message }
        let ns = error as NSError
        return "Das hat nicht geklappt (\(ns.domain) \(ns.code)). Ziehe zum Neuladen nach unten."
    }
}
