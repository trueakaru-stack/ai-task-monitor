import Foundation
import XCTest
@testable import AITaskMonitor

final class ExternalProviderTaskMapperTests: XCTestCase {
    func testTasksPreserveProviderWaitingPlanAndSafeAction() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ExternalProviderStateStore()
        func apply(_ json: String) throws {
            let event = try XCTUnwrap(ExternalProviderEventParser.parse(Data(json.utf8)))
            XCTAssertTrue(store.apply(event, now: now))
        }
        try apply(#"{"version":1,"provider":"deepseek","session":"one","kind":"tool_started","call":"call_1","action":"command"}"#)
        try apply(#"{"version":1,"provider":"deepseek","session":"one","kind":"plan","steps":[{"title":"One","status":"done"},{"title":"Two","status":"active"}]}"#)
        let epoch = DispatchTime.now().uptimeNanoseconds
        try apply(#"{"version":1,"provider":"hermes","session":"two","kind":"waiting","request":"request_1","epoch":\#(epoch),"tick":\#(epoch + 1)}"#)
        let tasks = ExternalProviderTaskMapper.tasks(store.snapshot(now: now))
        let deep = try XCTUnwrap(tasks.first { $0.provider == .deepseek })
        XCTAssertTrue(deep.isActive)
        XCTAssertFalse(deep.isWaiting)
        XCTAssertEqual(deep.progress, 50)
        XCTAssertEqual(deep.progressKind, .exact)
        XCTAssertEqual(deep.steps.map(\.status), [.done, .active])
        XCTAssertTrue(["Выполняет команду", "Running a command"].contains(deep.activity))
        let waiting = try XCTUnwrap(tasks.first { $0.provider == .hermes })
        XCTAssertTrue(waiting.isWaiting)
        XCTAssertFalse(waiting.isActive)
        XCTAssertFalse(waiting.isUnconfirmed)
        XCTAssertNil(waiting.progress)
        XCTAssertTrue(["Ожидает подтверждения", "Waiting for confirmation"].contains(waiting.activity))
        XCTAssertFalse(waiting.startKey.isEmpty)
        XCTAssertEqual(tasks.map(\.id).count, Set(tasks.map(\.id)).count)
    }

    func testSignalGapDoesNotClaimProgressOrActiveWork() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ExternalProviderStateStore()
        for json in [
            #"{"version":1,"provider":"opencode","session":"one","kind":"active"}"#,
            #"{"version":1,"provider":"opencode","session":"one","kind":"gap"}"#
        ] {
            let event = try XCTUnwrap(ExternalProviderEventParser.parse(Data(json.utf8)))
            XCTAssertTrue(store.apply(event, now: now))
        }
        let task = try XCTUnwrap(ExternalProviderTaskMapper.tasks(store.snapshot(now: now)).first)
        XCTAssertFalse(task.isActive)
        XCTAssertFalse(task.isWaiting)
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertNil(task.progress)
        XCTAssertTrue(["Статус не подтверждён", "Status unconfirmed"].contains(task.activity))
    }
}
