import SwiftUI
import AVFoundation

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.sessionId else { completionHandler(); return }
        AppEnvironment.shared.downloadManager.backgroundCompletion = completionHandler
    }
}

@main
struct GuevenTubeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Hintergrundwiedergabe: Audio-Sitzung "playback" (Info.plist: UIBackgroundModes=audio).
        Task { await AppEnvironment.shared.downloads.resumePending() }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup { RootView() }
    }
}
