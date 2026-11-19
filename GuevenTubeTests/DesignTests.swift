import XCTest
import SwiftUI
import GuevenCore
@testable import GuevenTube

/// Rendert die Kernbildschirme in Hoch- und Querformat als PNG nach /tmp/gt-shots (CI lädt sie als Artefakt hoch),
/// und prüft, dass die App Querformat überhaupt erlaubt.
@MainActor
final class DesignTests: XCTestCase {
    private let sample = VideoItem(videoId: "dQw4w9WgXcQ", title: "Ein ziemlich langer Videotitel, der über zwei Zeilen läuft und umbricht",
                                   channelName: "Beispielkanal", channelId: "UC123", thumbnailUrl: "", durationSeconds: 754,
                                   viewCountText: "1,2 Mio. Aufrufe", publishedText: "vor 3 Tagen")

    private func render<V: View>(_ view: V, size: CGSize, name: String, dark: Bool = true) {
        let content = view.frame(width: size.width, height: size.height).environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let data = renderer.uiImage?.pngData() else { return XCTFail("kein Bild für \(name)") }
        let dir = URL(fileURLWithPath: "/tmp/gt-shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNoThrow(try data.write(to: dir.appendingPathComponent("\(name).png")))
    }

    private func player(landscape: Bool, error: String? = nil) -> some View {
        PlayerContent(isLandscape: landscape, video: sample, hasCaptions: true, qualityText: "1080p · HLS", errorText: error, isLoading: error == nil,
                      skipLabel: "Sponsor überspringen", actions: PlayerActions(),
                      surface: { Color(white: 0.25) },
                      playlistMenu: { ChipLabel(title: "Playlist", systemImage: "text.badge.plus") },
                      downloadMenu: { ChipLabel(title: "Herunterladen", systemImage: "arrow.down.circle") })
    }

    func testRenderPlayerPortraitAndLandscape() {
        render(player(landscape: false), size: CGSize(width: 390, height: 844), name: "player-hochformat-dunkel")
        render(player(landscape: false), size: CGSize(width: 390, height: 844), name: "player-hochformat-hell", dark: false)
        render(player(landscape: true), size: CGSize(width: 844, height: 390), name: "player-querformat")
        render(player(landscape: false, error: "Server verweigert den Strom (HTTP 403)\nPO-Token: ok"), size: CGSize(width: 390, height: 844), name: "player-fehler")
    }

    func testRenderVideoCards() {
        let app = AppModel()
        let column = VStack(spacing: 0) {
            VideoRow(item: sample, style: .card)
            VideoRow(item: sample, style: .compact)
        }.environmentObject(app).background(GT.background)
        render(column, size: CGSize(width: 390, height: 420), name: "videozeilen-dunkel")
        render(column, size: CGSize(width: 390, height: 420), name: "videozeilen-hell", dark: false)
    }

    func testLandscapeIsAllowed() {
        let o = Bundle.main.object(forInfoDictionaryKey: "UISupportedInterfaceOrientations") as? [String] ?? []
        XCTAssertTrue(o.contains("UIInterfaceOrientationLandscapeLeft") && o.contains("UIInterfaceOrientationLandscapeRight"), "Info.plist erlaubt kein Querformat: \(o)")
    }
}
