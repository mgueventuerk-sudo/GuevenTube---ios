import SwiftUI
import GuevenCore

/// Brücke zwischen Oberfläche und Diensten: löst ein Video auf und startet die Wiedergabe. Apple-only, ungetestet.
@MainActor
final class AppModel: ObservableObject {
    let env = AppEnvironment.shared
    let player = PlayerManager()
    @Published private(set) var current: VideoItem?
    @Published private(set) var playbackError: String?
    @Published var showPlayer = false
    private var task: Task<Void, Never>?

    func play(_ item: VideoItem, audioOnly: Bool = false, showPlayer: Bool = true) {
        task?.cancel()
        current = item
        playbackError = nil
        self.showPlayer = showPlayer
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await env.resolver.resolve(item.videoId)
                try Task.checkCancellation()
                let plan = try PlaybackSourcePlanner.plan(resolved, audioOnly: audioOnly)
                player.play(plan, info: .init(title: item.title, artist: item.channelName ?? "",
                                              artworkUrl: URL(string: item.thumbnailUrl)))
            } catch is CancellationError {
            } catch {
                playbackError = String(describing: error)
            }
        }
    }

    func closePlayer() { task?.cancel(); player.stop(); current = nil; showPlayer = false }
}
