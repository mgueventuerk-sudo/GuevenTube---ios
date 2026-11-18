import XCTest
@testable import GuevenCore

/// Port von CommunityParserTest.kt.
final class CommunityParserTests: XCTestCase {
    private func json(_ text: String) -> JSON { try! JSONParser.parse(text) }

    func testFindsCommentsTokenInItemSection() {
        let next = json(#"""
        {"contents":{"twoColumnWatchNextResults":{"results":{"results":{"contents":[
          {"videoPrimaryInfoRenderer":{}},
          {"itemSectionRenderer":{"sectionIdentifier":"comment-item-section","contents":[
            {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"COMMENTS_TOKEN"}}}}]}}
        ]}}}}}
        """#)
        XCTAssertEqual(CommunityParser.findCommentsToken(next), "COMMENTS_TOKEN")
    }

    func testFindsCommentsTokenInEngagementPanel() {
        let next = json(#"""
        {"engagementPanels":[
          {"engagementPanelSectionListRenderer":{"panelIdentifier":"engagement-panel-structured-description",
            "content":{"continuationCommand":{"token":"WRONG"}}}},
          {"engagementPanelSectionListRenderer":{"panelIdentifier":"engagement-panel-comments-section",
            "content":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[
              {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"PANEL_TOKEN"}}}}]}}]}}}}
        ]}
        """#)
        XCTAssertEqual(CommunityParser.findCommentsToken(next), "PANEL_TOKEN")
    }

    func testNoTokenWithoutCommentSection() {
        XCTAssertNil(CommunityParser.findCommentsToken(json(#"{"contents":{}}"#)))
    }

    func testParsesEntityPayloadCommentsAndListContinuation() {
        let response = json(#"""
        {"onResponseReceivedEndpoints":[
          {"clearCommandsAndEndpoints":{}},
          {"reloadContinuationItemsCommand":{"continuationItems":[
            {"commentThreadRenderer":{"replies":{"commentRepliesRenderer":{"contents":[
              {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"REPLIES"}}}}]}}}},
            {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"NEXT_PAGE"}}}}
          ]}}
        ],
        "frameworkUpdates":{"entityBatchUpdate":{"mutations":[
          {"payload":{"commentEntityPayload":{"key":"k1",
            "properties":{"commentId":"c1","content":{"content":"Tolles Video!"},"publishedTime":"vor 2 Tagen"},
            "author":{"displayName":"@anna","avatarThumbnailUrl":"//yt3.ggpht.com/a.jpg"},
            "toolbar":{"likeCountNotliked":"12"}}}},
          {"payload":{"commentEntityPayload":{"key":"k2",
            "properties":{"commentId":"c2","content":{"content":"Zweiter"}},
            "author":{"displayName":"@ben"},
            "toolbar":{"likeCountNotliked":"0"}}}}
        ]}}}
        """#)
        let page = CommunityParser.parseComments(response)
        XCTAssertEqual(page.comments.map(\.id), ["c1", "c2"])
        let first = page.comments[0]
        XCTAssertEqual(first.author, "@anna")
        XCTAssertEqual(first.text, "Tolles Video!")
        XCTAssertEqual(first.likeText, "12")
        XCTAssertEqual(first.publishedText, "vor 2 Tagen")
        XCTAssertEqual(first.avatarUrl, "https://yt3.ggpht.com/a.jpg")
        XCTAssertNil(page.comments[1].likeText)
        XCTAssertEqual(page.continuation, "NEXT_PAGE")
    }

    func testDuplicateIdsKeepFirst() {
        let response = json(#"""
        {"a":{"commentEntityPayload":{"properties":{"commentId":"c1","content":{"content":"eins"}},"author":{}}},
         "b":{"commentEntityPayload":{"properties":{"commentId":"c1","content":{"content":"zwei"}},"author":{}}}}
        """#)
        let page = CommunityParser.parseComments(response)
        XCTAssertEqual(page.comments.count, 1)
        XCTAssertEqual(page.comments[0].text, "eins")
        XCTAssertEqual(page.comments[0].author, "Unbekannt")
    }

    func testParsesClassicCommentRenderer() {
        let response = json(#"""
        {"onResponseReceivedEndpoints":[{"appendContinuationItemsAction":{"continuationItems":[
          {"commentThreadRenderer":{"comment":{"commentRenderer":{"commentId":"x1",
            "authorText":{"simpleText":"Carla"},"contentText":{"runs":[{"text":"Hallo "},{"text":"Welt"}]},
            "publishedTimeText":{"runs":[{"text":"vor 1 Stunde"}]}}}}}
        ]}}]}
        """#)
        let page = CommunityParser.parseComments(response)
        XCTAssertEqual(page.comments.count, 1)
        XCTAssertEqual(page.comments[0].author, "Carla")
        XCTAssertEqual(page.comments[0].text, "Hallo Welt")
        XCTAssertEqual(page.comments[0].publishedText, "vor 1 Stunde")
        XCTAssertNil(page.continuation)
    }

    func testParsesLiveChatBatch() {
        let next = json(#"""
        {"contents":{"twoColumnWatchNextResults":{"conversationBar":{"liveChatRenderer":{"continuations":[
          {"reloadContinuationData":{"continuation":"CHAT_START"}}]}}}}}
        """#)
        XCTAssertEqual(CommunityParser.findLiveChatToken(next), "CHAT_START")

        let chat = json(#"""
        {"continuationContents":{"liveChatContinuation":{
          "continuations":[{"invalidationContinuationData":{"continuation":"CHAT_NEXT","timeoutMs":3500}}],
          "actions":[
            {"addChatItemAction":{"item":{"liveChatTextMessageRenderer":{"id":"m1",
              "authorName":{"simpleText":"Dora"},
              "message":{"runs":[{"text":"Hi "},{"emoji":{"shortcuts":[":wave:"]}}]}}}}},
            {"addChatItemAction":{"item":{"liveChatPaidMessageRenderer":{"id":"m2",
              "authorName":{"simpleText":"Emil"},"purchaseAmountText":{"simpleText":"5,00 €"}}}}},
            {"addChatItemAction":{"item":{"liveChatViewerEngagementMessageRenderer":{"id":"sys"}}}},
            {"markChatItemAsDeletedAction":{}}
          ]}}}
        """#)
        let batch = CommunityParser.parseLiveChat(chat)
        XCTAssertEqual(batch.messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(batch.messages[0].text, "Hi :wave:")
        XCTAssertEqual(batch.messages[0].author, "Dora")
        XCTAssertEqual(batch.messages[1].highlight, "5,00 €")
        XCTAssertEqual(batch.messages[1].text, "5,00 €")
        XCTAssertEqual(batch.continuation, "CHAT_NEXT")
        XCTAssertEqual(batch.timeoutMs, 3500)
    }

    func testLiveChatDefaultsWhenEmpty() {
        let batch = CommunityParser.parseLiveChat(json("{}"))
        XCTAssertTrue(batch.messages.isEmpty)
        XCTAssertNil(batch.continuation)
        XCTAssertEqual(batch.timeoutMs, CommunityParser.defaultChatTimeoutMs)
    }
}
