import AppKit
import XCTest
@testable import AITaskMonitor

final class FeedbackDraftTests: XCTestCase {
    func testDraftContainsOnlyAddressAndSubject() throws {
        let url = try XCTUnwrap(FeedbackDraft.url)
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "mailto")
        XCTAssertEqual(parts.path, "truea.k.a.ru@gmail.com")
        XCTAssertEqual(parts.queryItems?.map(\.name), ["subject"])
        XCTAssertFalse(url.absoluteString.contains("body="))
        XCTAssertEqual(String(FeedbackDraft.address.characters), "truea.k.a.ru@gmail.com")
        XCTAssertEqual(FeedbackDraft.address.runs.first?.link, url)
    }

    func testCopyWritesOnlyEmailToIsolatedPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.aitaskmonitor.feedback-test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(FeedbackDraft.copyAddress(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "truea.k.a.ru@gmail.com")
    }
}
