import SwiftUI
import AVFoundation

@main
struct GuevenTubeApp: App {
    init() {
        // Hintergrundwiedergabe: Audio-Sitzung "playback" (Info.plist: UIBackgroundModes=audio).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup { RootView() }
    }
}
