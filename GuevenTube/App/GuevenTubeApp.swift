import SwiftUI
import AVFoundation
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NewVideosService.register()
        UNUserNotificationCenter.current().delegate = self
        Task { if await AppEnvironment.shared.settings.current().newVideoNotifications { NewVideosService.schedule() } }
        return true
    }

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
        // Der PO-Token-Generator braucht ein Fenster: kurz nach dem Start im Hintergrund vorbauen.
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); await AppEnvironment.shared.poTokens.warmUp() }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup { RootView() }
    }
}
