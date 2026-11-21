import BackgroundTasks
import UserNotifications
import GuevenCore

/// Benachrichtigungen bei neuen Abo-Videos (Port von `NewVideosWorker.kt`). iOS entscheidet selbst, wann der
/// Hintergrundlauf stattfindet (`earliestBeginDate` ist nur ein Mindestabstand, keine Zusage) – anders als Android alle 3 h.
enum NewVideosService {
    static let taskId = "de.gueventube.app.newvideos"
    static let openVideoNotification = Notification.Name("gt.openVideo")
    private static let maxGuestChannels = 15
    /// Antippen bei Kaltstart: Die Meldung kommt, bevor `RootView` zuhört – darum hier vormerken, `RootView` holt es ab.
    @MainActor static var pendingVideo: VideoItem?

    /// Muss vor Ende von `application(_:didFinishLaunchingWithOptions:)` aufgerufen werden.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            schedule()
            let work = Task { task.setTaskCompleted(success: await run()) }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskId) }

    /// Fragt die Erlaubnis nur auf Wunsch (Schalter in den Einstellungen) – nie unaufgefordert beim Start.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// `false` = Abruf fehlgeschlagen (iOS darf später erneut versuchen).
    static func run() async -> Bool {
        let env = AppEnvironment.shared
        guard await env.settings.current().newVideoNotifications else { return true }
        let feed: [VideoItem]
        do {
            if await env.innerTube.hasAccount() {
                let json = try await env.innerTube.browse(browseId: InnerTubeService.browseSubscriptions)
                feed = InnerTubeParser.parseFeed(json, defaultShelfTitle: "Abos").shelves.flatMap(\.items)
            } else {
                var all: [VideoItem] = []
                for c in await env.library.subscriptions().prefix(maxGuestChannels) {
                    if Task.isCancelled { return false }
                    if let json = try? await env.innerTube.browse(browseId: c.channelId) {
                        all += InnerTubeParser.parseFeed(json, defaultShelfTitle: c.name).shelves.flatMap(\.items).prefix(3)
                    }
                }
                feed = all
            }
        } catch { return false }
        let fresh = NewVideoTracker(store: env.values).process(feed)
        guard !fresh.isEmpty else { return true }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return true }
        for v in fresh {
            let content = UNMutableNotificationContent()
            content.title = v.channelName ?? "Neues Video"
            content.body = v.title
            content.userInfo = ["videoId": v.videoId, "title": v.title, "channel": v.channelName ?? "", "thumb": v.thumbnailUrl]
            content.threadIdentifier = "new_videos"
            try? await center.add(UNNotificationRequest(identifier: "nv-\(v.videoId)", content: content, trigger: nil))
        }
        return true
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let id = info["videoId"] as? String else { return }
        let item = VideoItem(videoId: id, title: info["title"] as? String ?? "", channelName: (info["channel"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                             thumbnailUrl: info["thumb"] as? String ?? InnerTubeParser.fallbackThumbnail(id))
        await MainActor.run {
            NewVideosService.pendingVideo = item
            NotificationCenter.default.post(name: NewVideosService.openVideoNotification, object: item)
        }
    }
}
