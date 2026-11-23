import Foundation
import XCTest
@testable import AITaskMonitor

final class CodexActiveOperationTests: XCTestCase {
    private let reader = CodexTaskReader(codexHome: URL(fileURLWithPath: "/tmp/unused"))

    private func record(_ type: String, _ payload: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload]), as: UTF8.self)
    }

    private func started(_ turn: String = "turn-a") throws -> String {
        try record("event_msg", ["type": "task_started", "turn_id": turn])
    }

    private func summary() throws -> String {
        try record("event_msg", ["type": "agent_reasoning", "text": "**Fallback summary**\nPRIVATE_REASONING"])
    }

    private func call(_ id: String, title: String, namespace: String = "mcp__cua_repl",
                      name: String = "js", turn: String? = nil) throws -> String {
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["title": title, "code": "PRIVATE_CODE"]), as: UTF8.self)
        var payload: [String: Any] = ["type": "function_call", "namespace": namespace, "name": name,
                                      "call_id": id, "arguments": arguments]
        if let turn { payload["turn_id"] = turn }
        return try record("response_item", payload)
    }

    private func output(_ id: String) throws -> String {
        try record("response_item", ["type": "function_call_output", "call_id": id, "output": "PRIVATE_OUTPUT"])
    }

    private func activity(_ records: [String], sessionID: String? = nil) -> String {
        reader.parseActivity(from: records.joined(separator: "\n"), sessionID: sessionID)
    }

    private func figma(_ id: String = "figma-1", thread: String = "session-a", turn: String = "turn-a",
                       status: String = "completed", server: String = "codex_apps", tool: String = "figma.use_figma",
                       description: String = "Updated Figma", hasError: Bool = false,
                       resultIsError: Bool = false) throws -> String {
        var item: [String: Any] = ["id": id, "type": "McpToolCall", "server": server, "tool": tool, "status": status,
            "arguments": ["description": description, "code": "PRIVATE_JS", "file_key": "PRIVATE_FILE"],
            "result": ["text": "PRIVATE_OUTPUT", "isError": resultIsError]]
        if hasError { item["error"] = ["message": "PRIVATE_ERROR"] }
        return try record("event_msg", ["type": "item_completed", "thread_id": thread, "turn_id": turn, "item": item])
    }

    func testConfirmedOperationOverridesSummaryOnlyUntilItsOutput() throws {
        let start = try started(), fallback = try summary()
        let open = try call("call-a", title: "Проверка макета")
        let closed = try output("call-a")
        XCTAssertEqual(activity([start, fallback, open]), "Проверка макета")
        XCTAssertEqual(activity([start, fallback, open, closed]), "Fallback summary")
    }

    func testOperationRequiresVisibleStartAndMatchingTurn() throws {
        let fallback = try summary(), open = try call("call-a", title: "Open tool")
        XCTAssertEqual(activity([fallback, open]), "Fallback summary")
        XCTAssertEqual(activity([try started(""), fallback, open]), "Fallback summary")
        let turnStart = try record("event_msg", ["type": "turn_started", "turn_id": "turn-a"])
        XCTAssertEqual(activity([turnStart, fallback, open]), "Open tool")
        let wrongTurn = try call("call-b", title: "Another turn", turn: "turn-b")
        XCTAssertEqual(activity([try started(), fallback, wrongTurn]), "Fallback summary")
        let correctTurn = try call("call-c", title: "Current turn", turn: "turn-a")
        XCTAssertEqual(activity([try started(), fallback, correctTurn]), "Current turn")
    }

    func testLatestStillOpenCallWinsAndDuplicatesDoNotReviveIt() throws {
        let start = try started(), fallback = try summary()
        let first = try call("call-a", title: "First")
        let second = try call("call-b", title: "Second")
        let finishFirst = try output("call-a"), finishSecond = try output("call-b")
        XCTAssertEqual(activity([start, fallback, first, second, first]), "Second")
        XCTAssertEqual(activity([start, fallback, first, second, finishSecond, second]), "First")
        XCTAssertEqual(activity([start, fallback, first, second, finishSecond, finishFirst]), "Fallback summary")
        XCTAssertEqual(activity([start, fallback, finishFirst, first]), "Fallback summary")
    }

    func testTurnBoundariesClearOpenOperations() throws {
        let start = try started(), fallback = try summary(), open = try call("call-a", title: "Open tool")
        for terminal in ["task_complete", "turn_complete", "turn_aborted"] {
            let end = try record("event_msg", ["type": terminal, "turn_id": "turn-a"])
            XCTAssertEqual(activity([start, fallback, open, end]), "Fallback summary")
        }
        let next = try started("turn-b")
        XCTAssertEqual(activity([start, fallback, open, next]), "")
        let nextCall = try call("call-a", title: "Next turn")
        XCTAssertEqual(activity([start, fallback, open, next, nextCall]), "Next turn")
        let differentTurnEnd = try record("event_msg", ["type": "turn_complete", "turn_id": "turn-b"])
        XCTAssertEqual(activity([start, fallback, open, differentTurnEnd]), "Open tool")
    }

    func testBlankMalformedAndOtherToolsDoNotInventAnOperation() throws {
        let start = try started(), fallback = try summary()
        let blank = try call("blank", title: " \n ")
        let malformed = try record("response_item", ["type": "function_call", "namespace": "mcp__cua_repl", "name": "js",
                                                     "call_id": "malformed", "arguments": "{PRIVATE_CODE"])
        let otherNamespace = try call("other", title: "Private other tool", namespace: "functions")
        let otherName = try call("other-name", title: "Private different tool", name: "other")
        let unrelatedCompleted = try record("event_msg", ["type": "item_completed", "item": ["type": "CommandExecution", "command": "PRIVATE_COMMAND"]])
        XCTAssertEqual(activity([start, fallback, blank, malformed, otherNamespace, otherName, unrelatedCompleted]), "Fallback summary")

        let open = try call("call-a", title: "Open tool")
        let unknownOutput = try record("response_item", ["type": "function_call_output", "output": "PRIVATE_OUTPUT"])
        XCTAssertEqual(activity([start, fallback, open, unknownOutput]), "Fallback summary")
    }

    func testTitleIsNotTruncatedAndOversizedInputsAreIgnored() throws {
        let start = try started(), fallback = try summary()
        let fullTitle = String(repeating: "А", count: 4_096)
        XCTAssertEqual(activity([start, fallback, try call("full", title: fullTitle)]), fullTitle)
        let tooLong = try call("long", title: fullTitle + "Б")
        XCTAssertEqual(activity([start, fallback, tooLong]), "Fallback summary")
        let oversizedArguments = try record("response_item", ["type": "function_call", "namespace": "mcp__cua_repl", "name": "js",
            "call_id": "oversized", "arguments": String(repeating: "x", count: 1_048_577)])
        XCTAssertEqual(activity([start, fallback, oversizedArguments]), "Fallback summary")
        let nonStringTitle = try record("response_item", ["type": "function_call", "namespace": "mcp__cua_repl", "name": "js",
            "call_id": "number", "arguments": #"{"title":123}"#])
        XCTAssertEqual(activity([start, fallback, nonStringTitle]), "Fallback summary")
    }

    func testOnlySupportedASCIIIDsCanBeCurrentOperations() throws {
        let start = try started(), fallback = try summary()
        let supported = try call("AZaz09_-", title: "Supported ID")
        XCTAssertEqual(activity([start, fallback, supported]), "Supported ID")
        let maximum = try call(String(repeating: "A", count: 256), title: "Maximum ID")
        XCTAssertEqual(activity([start, fallback, maximum]), "Maximum ID")
        let oversized = try call(String(repeating: "A", count: 257), title: "Oversized ID")
        let slash = try call("call/invalid", title: "Slash ID")
        let emoji = try call("call-😀", title: "Emoji ID")
        for unsupported in [oversized, slash, emoji] {
            XCTAssertEqual(activity([start, fallback, unsupported]), "Fallback summary")
            XCTAssertEqual(activity([start, fallback, supported, unsupported]), "Supported ID")
        }
    }

    func testLegacyCommentaryIsFallbackAndBlankEventsDoNotEraseIt() throws {
        let start = try started()
        let commentary = try record("event_msg", ["type": "agent_message", "phase": "commentary", "message": "Agent update"])
        let blank = try record("event_msg", ["type": "agent_message", "phase": "commentary", "message": "  \n "])
        let final = try record("event_msg", ["type": "agent_message", "phase": "final_answer", "message": "FINAL_ANSWER"])
        XCTAssertEqual(activity([start, commentary, blank, final]), "Agent update")
        let fallback = try summary()
        XCTAssertEqual(activity([start, fallback, commentary]), "Agent update")
        XCTAssertEqual(activity([start, commentary, fallback]), "Fallback summary")
        let userCommentary = try record("response_item", ["type": "message", "role": "user", "phase": "commentary",
            "content": [["type": "output_text", "text": "PRIVATE_USER_TEXT"]]])
        XCTAssertEqual(activity([start, fallback, userCommentary]), "Fallback summary")
        let unknownRoles: [Any] = [NSNull(), 4, ""]
        for role in unknownRoles {
            let unknown = try record("response_item", ["type": "message", "role": role, "phase": "commentary",
                "content": [["type": "output_text", "text": "PRIVATE_UNKNOWN_TEXT"]]])
            XCTAssertEqual(activity([start, fallback, unknown]), "Fallback summary")
        }
        let roleless = try record("response_item", ["type": "message", "phase": "commentary",
            "content": [["type": "output_text", "text": "PRIVATE_ROLELESS_TEXT"]]])
        XCTAssertEqual(activity([start, fallback, roleless]), "Fallback summary")
        let blankSummary = try record("event_msg", ["type": "agent_reasoning", "text": "   "])
        XCTAssertEqual(activity([start, fallback, blankSummary]), "Fallback summary")
    }

    func testUnreadableRecordSuppressesOpenCallsUntilANewTurn() throws {
        let start = try started(), fallback = try summary(), open = try call("call-a", title: "Open tool")
        let truncatedOutput = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call-a""#
        XCTAssertEqual(activity([start, fallback, open, truncatedOutput]), "Fallback summary")
        let laterCall = try call("call-b", title: "Later tool")
        XCTAssertEqual(activity([start, fallback, open, truncatedOutput, laterCall]), "Fallback summary")
        let nextTurn = try started("turn-b")
        XCTAssertEqual(activity([start, fallback, open, truncatedOutput, nextTurn, laterCall]), "Later tool")
    }

    func testOversizedRecordSuppressesOpenCallsButNotEarlierFallback() throws {
        let start = try started(), fallback = try summary(), open = try call("call-a", title: "Open tool")
        let oversized = String(repeating: "x", count: 1_048_577)
        XCTAssertEqual(activity([start, fallback, open, oversized]), "Fallback summary")
    }

    func testOversizedValidUTF8OutputSuppressesOpenCall() throws {
        let start = try started(), fallback = try summary(), open = try call("call-a", title: "Open tool")
        let output = try record("response_item", ["type": "function_call_output", "call_id": "call-a",
            "output": String(repeating: "я", count: 600_000)])
        XCTAssertGreaterThan(output.utf8.count, 1_048_576)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(activity([start, fallback, open, output]), "Fallback summary")
    }

    func testValidRecordWithoutPayloadSuppressesOpenCall() throws {
        let start = try started(), fallback = try summary(), open = try call("call-a", title: "Open tool")
        let missingPayload = #"{"type":"event_msg"}"#
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(missingPayload.utf8)) as? [String: Any])
        XCTAssertEqual(activity([start, fallback, open, missingPayload]), "Fallback summary")
    }

    func testRecentOperationWorksInLongTurnAndOlderOneFallsBack() throws {
        let start = try started(), fallback = try summary(), open = try call("call-a", title: "Recent operation")
        let filler = try record("event_msg", ["type": "token_count"])
        XCTAssertEqual(activity([start, fallback] + Array(repeating: filler, count: 5_000) + [open]), "Recent operation")
        XCTAssertEqual(activity([start, fallback, open] + Array(repeating: filler, count: 511)), "Recent operation")
        XCTAssertEqual(activity([start, fallback, open] + Array(repeating: filler, count: 512)), "Fallback summary")
    }

    func testDuplicateFromBeforeWindowDoesNotReviveOldOperation() throws {
        let start = try started(), fallback = try summary(), open = try call("call-a", title: "Old operation")
        let filler = try record("event_msg", ["type": "token_count"])
        let gap = Array(repeating: filler, count: 512)
        XCTAssertEqual(activity([start, fallback, open] + gap + [open]), "Fallback summary")
        let oldOutput = try output("call-a")
        XCTAssertEqual(activity([start, fallback, oldOutput] + gap + [open]), "Fallback summary")
        let arbitraryMention = try record("event_msg", ["type": "token_count", "note": "earlier call-a marker"])
        XCTAssertEqual(activity([start, fallback, arbitraryMention] + gap + [open]), "Fallback summary")
        let next = try started("turn-b")
        XCTAssertEqual(activity([start, fallback, open] + gap + [next, open]), "Old operation")
    }

    func testUnicodeEscapedEarlierCallIDDoesNotReviveOldOperation() throws {
        let start = try started(), fallback = try summary(), open = try call("call-a", title: "Old operation")
        let escaped = #"{"type":"response_item","payload":{"type":"function_call","call_id":"call-\u0061"}}"#
        XCTAssertFalse(escaped.contains("call-a"))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(escaped.utf8)) as? [String: Any])
        let payload = try XCTUnwrap(parsed["payload"] as? [String: Any])
        XCTAssertEqual(payload["call_id"] as? String, "call-a")
        let filler = try record("event_msg", ["type": "token_count"])
        XCTAssertEqual(activity([start, fallback, escaped] + Array(repeating: filler, count: 512) + [open]), "Fallback summary")

        let escapedMention = #"{"type":"event_msg","payload":{"type":"token_count","note":"call-\u0061"}}"#
        XCTAssertEqual(activity([start, fallback, escapedMention] + Array(repeating: filler, count: 512) + [open]), "Fallback summary")

    }

    func testLatestFigmaDescriptionIsLabeledAndLosesToNewerNarration() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let start = try started(), fallback = try summary(), action = try figma()
        XCTAssertEqual(activity([start, fallback, action], sessionID: "session-a"), "Last Figma action: Updated Figma")
        XCTAssertEqual(activity([start, action, fallback], sessionID: "session-a"), "Fallback summary")
        let commentary = try record("event_msg", ["type": "agent_message", "phase": "commentary", "message": "Newer commentary"])
        XCTAssertEqual(activity([start, action, commentary], sessionID: "session-a"), "Newer commentary")
        XCTAssertEqual(activity([start, fallback, action, commentary], sessionID: "session-a"), "Newer commentary")
        let newer = try figma("figma-2", description: "Another action")
        XCTAssertEqual(activity([start, action, commentary, newer], sessionID: "session-a"), "Last Figma action: Another action")
        AppLanguage.previewOverride = .ru
        XCTAssertEqual(activity([start, fallback, action], sessionID: "session-a"), "Последнее действие в Figma: Updated Figma")
    }

    func testOpenCUACallHasPriorityOverCompletedFigma() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let start = try started(), fallback = try summary(), open = try call("cua-1", title: "Current CUA")
        let action = try figma(), end = try output("cua-1")
        XCTAssertEqual(activity([start, fallback, open, action], sessionID: "session-a"), "Current CUA")
        XCTAssertEqual(activity([start, fallback, open, action, end], sessionID: "session-a"), "Last Figma action: Updated Figma")
    }

    func testFigmaNeedsMatchingThreadAndTurnAndOnlyAcceptsSuccessfulTarget() throws {
        let start = try started(), fallback = try summary()
        let wrongThread = try figma(thread: "other-session")
        let wrongTurn = try figma(turn: "other-turn")
        let failed = try figma(status: "failed")
        let inProgress = try figma(status: "inProgress")
        let failedWithError = try figma(hasError: true)
        let otherServer = try figma(server: "another_app")
        let otherTool = try figma(tool: "figma.other")
        let missingID = try figma("")
        let slashID = try figma("figma/1")
        let emojiID = try figma("figma-😀")
        let oversizedID = try figma(String(repeating: "A", count: 257))
        let blankDescription = try figma(description: " \n ")
        let tooLong = try figma(description: String(repeating: "A", count: 4_097))
        for invalid in [wrongThread, wrongTurn, failed, inProgress, failedWithError, otherServer, otherTool, missingID, slashID, emojiID, oversizedID, blankDescription, tooLong] {
            XCTAssertEqual(activity([start, fallback, invalid], sessionID: "session-a"), "Fallback summary")
        }
        let action = try figma()
        XCTAssertEqual(activity([start, fallback, action]), "Fallback summary")
        XCTAssertEqual(activity([fallback, action], sessionID: "session-a"), "Fallback summary")
        XCTAssertEqual(activity([try started(""), fallback, action], sessionID: "session-a"), "Fallback summary")
    }

    func testDuplicateFigmaCompletionCannotOverrideNewerSummary() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let start = try started(), action = try figma(), fallback = try summary()
        XCTAssertEqual(activity([start, fallback, action, action], sessionID: "session-a"), "Last Figma action: Updated Figma")
        XCTAssertEqual(activity([start, action, fallback, action], sessionID: "session-a"), "Fallback summary")
        let later = try figma("figma-2", description: "Fresh Figma action")
        XCTAssertEqual(activity([start, action, fallback, action, later], sessionID: "session-a"), "Last Figma action: Fresh Figma action")
        let changed = try figma("figma-1", description: "Conflicting duplicate")
        XCTAssertEqual(activity([start, fallback, action, changed], sessionID: "session-a"), "Fallback summary")
        let failed = try figma("figma-1", status: "failed")
        XCTAssertEqual(activity([start, fallback, failed, action], sessionID: "session-a"), "Fallback summary")
        XCTAssertEqual(activity([start, fallback, action, failed], sessionID: "session-a"), "Fallback summary")
        XCTAssertEqual(activity([start, fallback, failed, action, later], sessionID: "session-a"), "Last Figma action: Fresh Figma action")
    }

    func testLaterOtherToolOrFigmaErrorHidesPriorFigmaAction() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let start = try started(), fallback = try summary(), action = try figma()
        let other = try record("event_msg", ["type": "item_completed", "thread_id": "session-a", "turn_id": "turn-a",
            "item": ["type": "CommandExecution", "id": "command-1", "command": "PRIVATE_COMMAND"]])
        XCTAssertEqual(activity([start, fallback, action, other], sessionID: "session-a"), "Fallback summary")
        XCTAssertEqual(activity([start, fallback, other, action], sessionID: "session-a"), "Last Figma action: Updated Figma")
        let foreign = try record("event_msg", ["type": "item_completed", "thread_id": "other-session", "turn_id": "turn-a",
            "item": ["type": "CommandExecution", "id": "command-2"]])
        XCTAssertEqual(activity([start, fallback, action, foreign], sessionID: "session-a"), "Last Figma action: Updated Figma")
        let error = try figma("figma-error", hasError: true)
        XCTAssertEqual(activity([start, fallback, action, error], sessionID: "session-a"), "Fallback summary")
        let invalidID = try figma("figma/invalid")
        XCTAssertEqual(activity([start, fallback, action, invalidID], sessionID: "session-a"), "Fallback summary")
        for identity in [["thread_id": "session-a"], ["turn_id": "turn-a"], [:]] {
            var payload: [String: Any] = ["type": "item_completed", "item": ["type": "CommandExecution", "id": "unknown"]]
            for (key, value) in identity { payload[key] = value }
            let unbound = try record("event_msg", payload)
            XCTAssertEqual(activity([start, fallback, action, unbound], sessionID: "session-a"), "Fallback summary")
        }
        let foreignWithoutTurn = try record("event_msg", ["type": "item_completed", "thread_id": "other-session",
            "item": ["type": "CommandExecution", "id": "foreign"]])
        XCTAssertEqual(activity([start, fallback, action, foreignWithoutTurn], sessionID: "session-a"), "Last Figma action: Updated Figma")
    }

    func testUnreadableEventPreventsClaimingFigmaIsLatest() throws {
        let start = try started(), fallback = try summary(), action = try figma()
        XCTAssertEqual(activity([start, fallback, action, "{broken"], sessionID: "session-a"), "Fallback summary")
    }

    func testCompletedFigmaWithResultErrorUsesFallback() throws {
        let start = try started(), fallback = try summary()
        let action = try figma(status: "completed", resultIsError: true)
        XCTAssertEqual(activity([start, fallback, action], sessionID: "session-a"), "Fallback summary")
        let previous = try figma("previous")
        XCTAssertEqual(activity([start, fallback, previous, action], sessionID: "session-a"), "Fallback summary")
    }

    func testUnboundCompletedMessagesDoNotOverrideCurrentActivity() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let start = try started(), fallback = try summary(), action = try figma()
        let items: [[String: Any]] = [
            ["type": "Reasoning", "summary_text": ["UNBOUND_SUMMARY"]],
            ["type": "AgentMessage", "phase": "commentary", "content": [["type": "Text", "text": "UNBOUND_MESSAGE"]]]
        ]
        for item in items {
            for identity in [["thread_id": "session-a"], ["turn_id": "turn-a"], [:]] {
                var payload: [String: Any] = ["type": "item_completed", "item": item]
                for (key, value) in identity { payload[key] = value }
                XCTAssertEqual(activity([start, fallback, action, try record("event_msg", payload)], sessionID: "session-a"),
                               "Fallback summary")
            }
        }
    }

    func testMalformedFigmaErrorFlagIsNotSuccessful() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let start = try started(), fallback = try summary()
        let invalidValues: [Any] = ["true", "false", NSNull(), ["unexpected": true]]
        for value in invalidValues {
            let item: [String: Any] = ["id": "figma-invalid", "type": "McpToolCall", "server": "codex_apps",
                "tool": "figma.use_figma", "status": "completed", "arguments": ["description": "Not confirmed"],
                "result": ["isError": value]]
            let event = try record("event_msg", ["type": "item_completed", "thread_id": "session-a", "turn_id": "turn-a", "item": item])
            XCTAssertEqual(activity([start, fallback, event], sessionID: "session-a"), "Fallback summary")
        }
    }
}
