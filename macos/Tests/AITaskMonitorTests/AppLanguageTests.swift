import XCTest
@testable import AITaskMonitor

final class AppLanguageTests: XCTestCase {
    func testSystemLocaleAndExplicitOverride() {
        XCTAssertEqual(AppLanguage.resolve(.system, preferredLanguages: ["ru-RU"]), .ru)
        XCTAssertEqual(AppLanguage.resolve(.system, preferredLanguages: ["ru_Cyrl_RU"]), .ru)
        XCTAssertEqual(AppLanguage.resolve(.system, preferredLanguages: ["en-US"]), .en)
        XCTAssertEqual(AppLanguage.resolve(.system, preferredLanguages: ["fr-FR", "ru-RU"]), .en)
        XCTAssertEqual(AppLanguage.resolve(.system, preferredLanguages: []), .en)
        XCTAssertEqual(AppLanguage.resolve(.ru, preferredLanguages: ["en-US"]), .ru)
        XCTAssertEqual(AppLanguage.resolve(.en, preferredLanguages: ["ru-RU"]), .en)
    }
}
