import Foundation

public struct Comment: Equatable, Sendable, Identifiable {
    public var id: String
    public var author: String
    public var text: String
    public var publishedText: String?
    public var likeText: String?
    public var avatarUrl: String?
    public init(id: String, author: String, text: String, publishedText: String? = nil, likeText: String? = nil, avatarUrl: String? = nil) {
        self.id = id; self.author = author; self.text = text; self.publishedText = publishedText; self.likeText = likeText; self.avatarUrl = avatarUrl
    }
}

public struct CommentsPage: Equatable, Sendable {
    public var comments: [Comment]
    public var continuation: String?
}

public struct ChatMessage: Equatable, Sendable, Identifiable {
    public var id: String
    public var author: String
    public var text: String
    public var highlight: String?
}

public struct ChatBatch: Equatable, Sendable {
    public var messages: [ChatMessage]
    public var continuation: String?
    public var timeoutMs: Int64
}

/// Port von `CommunityParser` (Android `CommunityRepositories.kt`): Kommentare und Live-Chat als reine Funktionen.
public enum CommunityParser {
    public static let defaultChatTimeoutMs: Int64 = 5_000

    /// Fortsetzungstoken der ersten Kommentarseite aus einer Web-`/next`-Antwort.
    public static func findCommentsToken(_ root: JSON) -> String? {
        if let token = root.findAll("itemSectionRenderer").first(where: { $0.str("sectionIdentifier") == "comment-item-section" })?
            .findFirst("continuationCommand")?.str("token") { return token }
        return (root.arr("engagementPanels") ?? [])
            .compactMap { $0.obj("engagementPanelSectionListRenderer") }
            .first { $0.str("panelIdentifier")?.contains("comment") == true }?
            .findFirst("continuationCommand")?.str("token")
    }

    /// Kommentare einer Fortsetzungsantwort – neues Format (Entity-Payloads) und klassisches `commentRenderer`.
    public static func parseComments(_ root: JSON) -> CommentsPage {
        var order: [String] = []
        var byId: [String: Comment] = [:]
        func add(_ c: Comment) { if byId[c.id] == nil { byId[c.id] = c; order.append(c.id) } }

        for payload in root.findAll("commentEntityPayload") {
            let properties = payload.obj("properties")
            guard let id = properties.str("commentId") ?? payload.str("key"),
                  let text = properties.obj("content").str("content") else { continue }
            let author = payload.obj("author")
            let likes = payload.obj("toolbar").str("likeCountNotliked").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0 == "0" ? nil : $0 }
            add(Comment(id: id, author: author.str("displayName") ?? "Unbekannt", text: text,
                        publishedText: properties.str("publishedTime"), likeText: likes,
                        avatarUrl: author.str("avatarThumbnailUrl").map(normalizeUrl)))
        }
        if order.isEmpty {
            for node in root.findAll("commentRenderer") {
                guard let id = node.str("commentId"), let text = node.text("contentText") else { continue }
                add(Comment(id: id, author: node.text("authorText") ?? "Unbekannt", text: text,
                            publishedText: node.text("publishedTimeText"), likeText: node.text("voteCount"),
                            avatarUrl: node.obj("authorThumbnail").arr("thumbnails").bestThumbnailUrl(88)))
            }
        }
        return CommentsPage(comments: order.compactMap { byId[$0] }, continuation: findCommentsContinuation(root))
    }

    /// Nächste Kommentarseite – nur die Fortsetzung der Liste, nicht die der Antwort-Threads.
    private static func findCommentsContinuation(_ root: JSON) -> String? {
        let endpoints = (root.arr("onResponseReceivedEndpoints") ?? []) + (root.arr("onResponseReceivedActions") ?? [])
        for endpoint in endpoints.reversed() {
            guard let items = endpoint.obj("reloadContinuationItemsCommand").arr("continuationItems")
                ?? endpoint.obj("appendContinuationItemsAction").arr("continuationItems") else { continue }
            if let token = items.last?.obj("continuationItemRenderer")?.findFirst("continuationCommand")?.str("token") { return token }
        }
        return nil
    }

    /// Erstes Live-Chat-Token aus einer Web-`/next`-Antwort.
    public static func findLiveChatToken(_ root: JSON) -> String? {
        root.findFirst("liveChatRenderer")?.arr("continuations")?
            .lazy.compactMap { $0.obj("reloadContinuationData").str("continuation") }.first
    }

    public static func parseLiveChat(_ root: JSON) -> ChatBatch {
        let chat = root.path("continuationContents", "liveChatContinuation")
        let messages: [ChatMessage] = (chat.arr("actions") ?? []).compactMap { action in
            guard let item = action.path("addChatItemAction", "item") else { return nil }
            if let m = item.obj("liveChatTextMessageRenderer") { return message(m, highlight: nil) }
            if let m = item.obj("liveChatPaidMessageRenderer") { return message(m, highlight: m.text("purchaseAmountText")) }
            return nil
        }
        let continuation = chat.arr("continuations")?.first
        let data = continuation.obj("timedContinuationData") ?? continuation.obj("invalidationContinuationData")
            ?? continuation.obj("reloadContinuationData")
        return ChatBatch(messages: messages, continuation: data.str("continuation"), timeoutMs: data.long("timeoutMs") ?? defaultChatTimeoutMs)
    }

    private static func message(_ node: JSON, highlight: String?) -> ChatMessage? {
        guard let id = node.str("id") else { return nil }
        let runs = node.obj("message").arr("runs") ?? []
        var text = runs.map(runText).joined()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = highlight ?? "" }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return ChatMessage(id: id, author: node.text("authorName") ?? "", text: text, highlight: highlight)
    }

    private static func runText(_ run: JSON) -> String {
        run.str("text") ?? run.obj("emoji").arr("shortcuts")?.first.asText() ?? ""
    }
}
