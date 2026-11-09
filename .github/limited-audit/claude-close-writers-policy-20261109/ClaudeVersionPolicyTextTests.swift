import Foundation
import XCTest
@testable import AITaskMonitor

// Text requirements only: these tests do not establish which Claude versions
// are installed and do not access an agent or a settings file.
final class ClaudeVersionPolicyTextTests: XCTestCase {
    @MainActor
    func testEveryConnectionStateShowsTheUnverifiedMinimumInBothLanguages() {
        let oldLanguage = AppLanguage.previewOverride
        defer { AppLanguage.previewOverride = oldLanguage }
        let connections: [ClaudeIntegration.ConnectionState?] = [nil, .disconnected, .partial, .connected]
        let installations: [ClaudeIntegration.InstallationState] = [.notFound, .unconfirmed, .available]

        for language in [AppLanguage.ru, .en] {
            AppLanguage.previewOverride = language
            for connection in connections {
                for installation in installations {
                    for unavailable in [false, true] {
                        let text = SettingsView.claudeSourceDescription(connection: connection, installation: installation,
                                                                        sourceUnavailable: unavailable)
                        XCTAssertTrue(text.contains("2.1.101"))
                        XCTAssertTrue(text.contains("Claude Desktop"))
                        if language == .ru {
                            XCTAssertTrue(text.contains("Перед подключением или отключением"))
                            XCTAssertTrue(text.contains("закройте Claude Code, Claude Desktop"))
                            XCTAssertTrue(text.contains("другие программы, которые меняют настройки Claude"))
                            XCTAssertTrue(text.contains("все используемые копии Claude Code"))
                            XCTAssertTrue(text.contains("в том числе в Claude Desktop"))
                            XCTAssertTrue(text.contains("или новее"))
                            XCTAssertTrue(text.contains("не проверяет закрытие программ и версии автоматически"))
                        } else {
                            XCTAssertTrue(text.contains("Before connecting or disconnecting"))
                            XCTAssertTrue(text.contains("close Claude Code, Claude Desktop"))
                            XCTAssertTrue(text.contains("other apps that modify Claude settings"))
                            XCTAssertTrue(text.contains("all copies of Claude Code you use"))
                            XCTAssertTrue(text.contains("including those in Claude Desktop"))
                            XCTAssertTrue(text.contains("or later"))
                            XCTAssertTrue(text.contains("does not automatically check whether apps are closed or versions are up to date"))
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func testExistingConnectionAndErrorGuidanceRemainsPresent() {
        let oldLanguage = AppLanguage.previewOverride
        defer { AppLanguage.previewOverride = oldLanguage }
        AppLanguage.previewOverride = .ru
        let partial = SettingsView.claudeSourceDescription(connection: .partial, installation: .available, sourceUnavailable: false)
        let disconnected = SettingsView.claudeSourceDescription(connection: .disconnected, installation: .notFound, sourceUnavailable: false)
        let connected = SettingsView.claudeSourceDescription(connection: .connected, installation: .available, sourceUnavailable: false)
        let unavailable = SettingsView.claudeSourceDescription(connection: .connected, installation: .available, sourceUnavailable: true)
        let invalid = SettingsView.claudeSourceDescription(connection: nil, installation: .available, sourceUnavailable: false)
        XCTAssertTrue(partial.contains("подключён частично"))
        XCTAssertTrue(partial.contains("восстановить недостающие hooks"))
        XCTAssertTrue(disconnected.contains("Claude Code не найден"))
        XCTAssertTrue(connected.contains("только локальные сессии"))
        XCTAssertTrue(connected.contains("перезапустите Claude Desktop или Claude Code"))
        XCTAssertTrue(unavailable.contains("Нет данных от Claude Code"))
        XCTAssertTrue(invalid.contains("Не удалось прочитать настройки"))
    }
}
