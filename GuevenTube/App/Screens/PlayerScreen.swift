import SwiftUI
import AVKit
import GuevenCore

struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}

struct PlayerScreen: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var player: PlayerManager
    @StateObject private var downloads = DownloadsModel()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                SystemPlayer(player: player.player)
                if case .loading = player.state, app.playbackError == nil { ProgressView().tint(.white) }
                if let msg = errorText { Text(msg).foregroundStyle(.white).padding().multilineTextAlignment(.center) }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                if let s = app.skipPrompt {
                    Button("\(s.category.displayName) überspringen") { app.skipPrompted() }
                        .buttonStyle(.borderedProminent).padding(.trailing, 12).padding(.bottom, 56)
                }
            }
            if let v = app.current {
                VStack(alignment: .leading, spacing: 6) {
                    Text(v.title).font(.headline)
                    Text(v.channelName ?? "").font(.subheadline).foregroundStyle(.secondary)
                    Menu("Herunterladen") {
                        ForEach([DownloadQuality.audioOnly, .hd, .fullHd], id: \.self) { q in
                            Button(q.label) { downloads.enqueue(v, quality: q) }
                        }
                    }
                    if let q = player.plan?.qualityLabel {
                        Text(q + (player.plan?.throttled == true ? " · gedrosselt" : "")).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            Spacer()
        }
        .overlay(alignment: .topTrailing) {
            Button { app.closePlayer() } label: { Image(systemName: "xmark.circle.fill").font(.title).padding() }
        }
    }

    private var errorText: String? {
        if let e = app.playbackError { return e }
        if case .failed(let m) = player.state { return m }
        return nil
    }
}
