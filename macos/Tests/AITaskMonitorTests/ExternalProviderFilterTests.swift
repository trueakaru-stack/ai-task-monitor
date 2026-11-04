import XCTest
@testable import AITaskMonitor

@MainActor
final class ExternalProviderFilterTests: XCTestCase {
    func testFiltersAndCountsForAllSixSources() {
        let store = TaskStore.manySourcesPreview()
        XCTAssertEqual(store.visibleProviderFilters.count, 7)
        XCTAssertEqual(store.count(for: .all), 6)
        for filter in ProviderFilter.allCases where filter != .all {
            XCTAssertEqual(store.count(for: filter), 1)
            store.selectedProvider = filter
            XCTAssertEqual(store.filteredTasks.count, 1)
            XCTAssertEqual(store.filteredTasks.first?.provider, filter.provider)
        }
    }
}
