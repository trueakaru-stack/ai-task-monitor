import Foundation
import XCTest
@testable import AITaskMonitor

@MainActor
final class ProviderCountsVisibilityTests: XCTestCase {
    private func task(_ provider: TaskProvider, _ id: String, active: Bool = false,
                      unconfirmed: Bool = false, waiting: Bool = false) -> MonitoredTask {
        MonitoredTask(id: id, provider: provider, title: "Synthetic task", activity: "Synthetic",
                      isActive: active, progress: nil, progressKind: .none, steps: [],
                      updatedAt: Date(), isUnconfirmed: unconfirmed, isWaiting: waiting)
    }

    func testEveryCounterMatchesTheCardsForItsFilter() {
        let cards = TaskProvider.allCases.flatMap { provider in
            [task(provider, provider.rawValue + "-active", active: true),
             task(provider, provider.rawValue + "-unknown", unconfirmed: true),
             task(provider, provider.rawValue + "-waiting", waiting: true)]
        }
        let store = TaskStore(previewTasks: cards)
        XCTAssertEqual(store.visibleProviderFilters, ProviderFilter.allCases)
        XCTAssertEqual(store.count(for: .all), 18, "Every visible card must be included")
        for filter in ProviderFilter.allCases {
            store.selectedProvider = filter
            let expected = filter == .all ? 18 : 3
            XCTAssertEqual(store.filteredTasks.count, expected)
            XCTAssertEqual(store.count(for: filter), store.filteredTasks.count)
            if let provider = filter.provider {
                XCTAssertTrue(store.filteredTasks.allSatisfy { $0.provider == provider })
            }
        }
        XCTAssertEqual(store.count(for: .all), 18, "Other counters do not depend on the selected tab")
    }

    func testUnconfirmedOnlyCardsAreCountedAndEmptyFiltersAreZero() {
        let store = TaskStore(previewTasks: [task(.opencode, "uncertain", unconfirmed: true)])
        XCTAssertEqual(store.visibleProviderFilters, [.all, .opencode])
        XCTAssertEqual(store.count(for: .all), 1)
        XCTAssertEqual(store.count(for: .opencode), 1)
        store.selectedProvider = .opencode
        XCTAssertEqual(store.filteredTasks.count, 1)
        store.selectedProvider = .claude
        XCTAssertEqual(store.filteredTasks.count, 0)
        XCTAssertEqual(store.count(for: .claude), 0)
        let empty = TaskStore(previewTasks: [])
        XCTAssertEqual(empty.visibleProviderFilters, [.all])
        XCTAssertTrue(ProviderFilter.allCases.allSatisfy { empty.count(for: $0) == 0 })
    }
}
