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
    @Published private(set) var skipPrompt: SponsorSegment?
    private var skipPlanner: SponsorSkipPlanner?
    private var task: Task<Void, Never>?

    init() {
        player.onPosition = { [weak self] ms in self?.handleSkip(ms) }
    }

    func play(_ item: VideoItem, audioOnly: Bool = false, showPlayer: Bool = true) {
        task?.cancel()
        current = item
        skipPlanner = nil; skipPrompt = nil
        playbackError = nil
        self.showPlayer = showPlayer
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await env.resolver.resolve(item.videoId)
                try Task.checkCancellation()
                let plan = try PlaybackSourcePlanner.plan(resolved, audioOnly: audioOnly)
                Task { await self.loadSponsorSegments(item.videoId) }
                player.play(plan, info: .init(title: item.title, artist: item.channelName ?? "",
                                              artworkUrl: URL(string: item.thumbnailUrl)))
            } catch is CancellationError {
            } catch {
                playbackError = String(describing: error)
            }
        }
    }

    /// Lädt SponsorBlock-Segmente im Hintergrund; ohne Treffer oder bei Fehlern läuft die Wiedergabe unverändert.
    private func loadSponsorSegments(_ videoId: String) async {
        let settings = await env.settings.current()
        guard settings.sponsorBlockEnabled else { return }
        let categories = Set(SponsorCategory.allCases.filter { settings.skipMode($0) != .disabled })
        guard let segments = try? await env.sponsorBlock.segments(videoId, categories: categories), !segments.isEmpty,
              current?.videoId == videoId else { return }
        skipPlanner = SponsorSkipPlanner(segments: segments, enabled: true, mode: { settings.skipMode($0) })
    }

    private func handleSkip(_ ms: Int64) {
        guard var planner = skipPlanner else { return }
        let action = planner.update(positionMs: ms)
        skipPlanner = planner
        switch action {
        case .none: break
        case .seek(let to, _): player.seek(toMs: to)
        case .showPrompt(let s): skipPrompt = s
        case .hidePrompt: skipPrompt = nil
        }
    }

    func skipPrompted() {
        guard var planner = skipPlanner, let target = planner.skipPrompted() else { return }
        skipPlanner = planner; skipPrompt = nil
        player.seek(toMs: target)
    }

    func closePlayer() { task?.cancel(); skipPlanner = nil; skipPrompt = nil; player.stop(); current = nil; showPlayer = false }
}
