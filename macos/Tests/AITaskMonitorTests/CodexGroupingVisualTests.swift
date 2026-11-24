import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import AITaskMonitor

private struct SyntheticAgentTaskCard: View {
    @EnvironmentObject private var store: TaskStore

    var body: some View {
        if let task = store.tasks.first {
            TaskCardView(task: task, showProvider: false)
        }
    }
}

final class CodexGroupingVisualTests: XCTestCase {
    @MainActor
    func testAgentCountFollowsConfirmedStepAndPause() {
        defer { AppLanguage.previewOverride = nil }
        AppLanguage.previewOverride = .ru
        var task = MonitoredTask(id: "synthetic", provider: .codex, title: "Задача", activity: "",
            isActive: true, progress: 50, progressKind: .exact,
            steps: [TaskStep(title: "Первый", status: .done), TaskStep(title: "Второй", status: .active),
                    TaskStep(title: "Третий", status: .pending)], updatedAt: .distantPast,
            progressBasis: .steps, codexAgentCount: 3, codexAgentsUnconfirmed: true)
        XCTAssertEqual(task.activeAgentPlanStepIndex, 1)
        XCTAssertFalse(task.codexAgentCountAtTitle)
        XCTAssertEqual(task.compactProgressLabel, "Этап 2 из 3 (3 агента)")
        XCTAssertNil(task.compactExtraAgentStepLabel)
        XCTAssertEqual(task.codexAgentStatusLabel, "Статус агентов не подтверждён")
        task.codexAgentCountUnconfirmed = true
        XCTAssertEqual(task.codexAgentStatusLabel, "Число и статус агентов не подтверждены")
        task.codexAgentsUnconfirmed = false
        XCTAssertEqual(task.codexAgentStatusLabel, "Число агентов не подтверждено")
        task.codexAgentCountUnconfirmed = false
        task.codexAgentsUnconfirmed = true

        task.progressBasis = .task
        XCTAssertEqual(task.compactProgressLabel, "50%")
        XCTAssertEqual(task.compactExtraAgentStepLabel, "Этап 2 из 3 (3 агента)")
        task.steps[1].status = .done
        XCTAssertTrue(task.codexAgentCountAtTitle)
        XCTAssertNil(task.compactAgentStepLabel)
        task.steps[2].status = .active
        XCTAssertFalse(task.codexAgentCountAtTitle)
        XCTAssertEqual(task.activeAgentPlanStepIndex, 2)
        task.planConfirmed = false
        XCTAssertTrue(task.codexAgentCountAtTitle)
        task.planConfirmed = true
        task.steps[1].status = .active
        XCTAssertTrue(task.codexAgentCountAtTitle)
        task.steps[1].status = .done
        task.isUnconfirmed = true
        XCTAssertTrue(task.codexAgentCountAtTitle)
        task.isUnconfirmed = false
        task.codexAgentCount = 0
        XCTAssertNil(task.codexAgentStatusLabel)
        XCTAssertNil(task.compactAgentStepLabel)
        AppLanguage.previewOverride = .en
        task.codexAgentCount = 1
        task.progressBasis = .steps
        XCTAssertEqual(task.compactProgressLabel, "Step 3 of 3 (1 agent)")
        task.codexAgentCount = 2
        XCTAssertEqual(task.compactProgressLabel, "Step 3 of 3 (2 agents)")
    }

    #if DEBUG
    @MainActor
    func testExpandedAgentsFollowStepAndReturnToTitleWhenPlanCannotBeConfirmed() throws {
        let root = try claudeSyntheticDirectory(prefix: "aitm-agent-placement-")
        let agent = CodexAgentDetail(id: "agent", title: "Synthetic assistant", activity: "Last action",
                                     isActive: false, isUnconfirmed: true)
        var task = MonitoredTask(id: "synthetic", provider: .codex, title: "Task", activity: "",
            isActive: true, progress: nil, progressKind: .none,
            steps: [TaskStep(id: "first", title: "First", status: .done),
                    TaskStep(id: "second", title: "Second", status: .active),
                    TaskStep(id: "third", title: "Third", status: .pending)],
            updatedAt: .distantPast, codexAgentCount: 1, codexAgentsUnconfirmed: true, codexAgents: [agent])
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: root.appendingPathComponent("missing-codex")),
                              claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("missing-claude")),
                              previewTasks: [task])
        func placement() throws -> CodexAgentListPlacement {
            let current = try XCTUnwrap(store.tasks.first)
            return CodexAgentListPlacement(task: current, expanded: store.isCodexGroupExpanded(current.id))
        }
        XCTAssertEqual(try placement(), .hidden)
        store.toggleCodexGroup(task.id)
        XCTAssertEqual(try placement(), .step("second"))
        task.steps[1].status = .done
        task.steps[2].status = .active
        store.testReplacePreviewTasks([task])
        XCTAssertTrue(store.isCodexGroupExpanded(task.id))
        XCTAssertEqual(try placement(), .step("third"))
        task.steps[2].status = .pending
        store.testReplacePreviewTasks([task])
        XCTAssertEqual(try placement(), .title)
        task.steps[2].status = .active
        task.planConfirmed = false
        store.testReplacePreviewTasks([task])
        XCTAssertEqual(try placement(), .title)
        task.planConfirmed = true
        task.isUnconfirmed = true
        store.testReplacePreviewTasks([task])
        XCTAssertEqual(try placement(), .title)
        XCTAssertEqual(store.tasks.first?.codexAgentStatusLabel, task.codexAgentStatusLabel)
        task.isUnconfirmed = false
        task.steps[1].status = .active
        store.testReplacePreviewTasks([task])
        XCTAssertEqual(try placement(), .title, "Multiple active steps cannot establish a placement")
        task.steps[1].status = .done
        store.testReplacePreviewTasks([task])
        XCTAssertEqual(try placement(), .step("third"))
        store.toggleCodexGroup(task.id)
        XCTAssertEqual(try placement(), .hidden)
        XCTAssertEqual(CodexAgentList.expandedHeight(for: 1), 72)
        XCTAssertEqual(CodexAgentList.expandedHeight(for: 3), 192)
        XCTAssertEqual(CodexAgentList.expandedHeight(for: 100), 192)
    }

    @MainActor
    func testExpandedAgentsSharePlanScrollerAndCanReachTheEnd() throws {
        guard ProcessInfo.processInfo.environment["AITM_SYNTHETIC_REQUIRED"] == "1" else {
            throw XCTSkip("Requires the isolated hosted runner")
        }
        let root = try claudeSyntheticDirectory(prefix: "aitm-agent-scroll-")
        let agents = (1...9).map { number in
            CodexAgentDetail(id: "agent-\(number)", title: "Assistant \(number)", activity: "Last action \(number)",
                             isActive: false, isUnconfirmed: true)
        }
        let task = MonitoredTask(id: "synthetic", provider: .codex, title: "Task", activity: "",
            isActive: true, progress: nil, progressKind: .none,
            steps: [TaskStep(id: "first", title: "First", status: .done),
                    TaskStep(id: "active", title: "Active", status: .active)],
            updatedAt: .distantPast, codexAgentCount: agents.count, codexAgentsUnconfirmed: true, codexAgents: agents)
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: root.appendingPathComponent("missing-codex")),
                              claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("missing-claude")),
                              previewTasks: [task])
        NSApplication.shared.setActivationPolicy(.prohibited)
        let size = NSSize(width: 520, height: 600)
        let hosting = NSHostingView(rootView: SyntheticAgentTaskCard().environmentObject(store))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        func scrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
        }
        func findLastAgent(in view: NSView) -> TruncatingTextField? {
            if let field = view as? TruncatingTextField, field.stringValue == "Assistant 9" { return field }
            return view.subviews.lazy.compactMap { findLastAgent(in: $0) }.first
        }
        func lastAgentIsVisible(in scroll: NSScrollView) -> Bool {
            guard let document = scroll.documentView, let label = findLastAgent(in: document) else { return false }
            let visible = scroll.contentView.convert(scroll.contentView.bounds, to: hosting)
            let bounds = label.convert(label.bounds, to: hosting)
            return !bounds.isEmpty && visible.intersection(bounds).height >= bounds.height - 1
        }
        let initialViews = scrollViews(in: hosting)
        XCTAssertEqual(initialViews.count, 1)
        let initialScroll = try XCTUnwrap(initialViews.first)
        XCTAssertEqual(initialScroll.scrollerStyle, .overlay)
        let initialScrollerClass = initialScroll.verticalScroller.map { String(reflecting: type(of: $0)) }
        let initialScrollerHidden = initialScroll.verticalScroller?.isHidden
        let initialScrollerEnabled = initialScroll.verticalScroller?.isEnabled
        let initialHasVerticalScroller = initialScroll.hasVerticalScroller
        let initialAutohidesScrollers = initialScroll.autohidesScrollers
        let initialFrameSize = initialScroll.frame.size
        let initialClipSize = initialScroll.contentView.bounds.size
        store.toggleCodexGroup(task.id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        let views = scrollViews(in: hosting)
        XCTAssertEqual(views.count, 1, "The agent rows must share the plan's scroll view")
        let scroll = try XCTUnwrap(views.first)
        XCTAssertEqual(scroll.scrollerStyle, .legacy, "An expanded plan with overflowing agents needs a visible scrollbar")
        XCTAssertTrue(scroll.hasVerticalScroller)
        let indicator = try XCTUnwrap(scroll.verticalScroller)
        XCTAssertFalse(indicator.isHidden)
        XCTAssertTrue(indicator.isEnabled)
        XCTAssertLessThan(indicator.knobProportion, 1)
        let document = try XCTUnwrap(scroll.documentView)
        let clip = scroll.contentView
        let bottom = max(0, document.bounds.height - clip.bounds.height)
        XCTAssertGreaterThan(bottom, 1, "The fixture must exceed the visible plan area")
        let topY: CGFloat = document.isFlipped ? 0 : bottom
        let bottomY: CGFloat = document.isFlipped ? bottom : 0
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: topY))
        scroll.reflectScrolledClipView(clip)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: bottomY))
        scroll.reflectScrolledClipView(clip)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(clip.bounds.origin.y, bottomY, accuracy: 1)
        XCTAssertTrue(lastAgentIsVisible(in: scroll), "The last assistant must be visible at the end of the plan")
        var refreshed = task
        refreshed.steps = task.steps.map { TaskStep(title: $0.title, status: $0.status) }
        XCTAssertNotEqual(refreshed.steps.map(\.id), task.steps.map(\.id))
        store.testReplacePreviewTasks([refreshed])
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        let refreshedViews = scrollViews(in: hosting)
        XCTAssertEqual(refreshedViews.count, 1)
        let refreshedScroll = try XCTUnwrap(refreshedViews.first)
        let refreshedDocument = try XCTUnwrap(refreshedScroll.documentView)
        let refreshedClip = refreshedScroll.contentView
        let refreshedBottom = max(0, refreshedDocument.bounds.height - refreshedClip.bounds.height)
        XCTAssertGreaterThan(refreshedBottom, 1)
        let refreshedBottomY: CGFloat = refreshedDocument.isFlipped ? refreshedBottom : 0
        XCTAssertTrue(store.isCodexGroupExpanded(task.id))
        XCTAssertEqual(refreshedClip.bounds.origin.y, refreshedBottomY, accuracy: 1,
                       "Refreshing an equivalent plan must not move the open list away from the bottom")
        XCTAssertTrue(lastAgentIsVisible(in: refreshedScroll), "The last assistant must remain visible after refresh")
        store.toggleCodexGroup(task.id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        let collapsedViews = scrollViews(in: hosting)
        XCTAssertEqual(collapsedViews.count, 1)
        let collapsedScroll = try XCTUnwrap(collapsedViews.first)
        XCTAssertEqual(collapsedScroll.scrollerStyle, .overlay, "Collapsing must restore the plan's existing scrollbar style")
        XCTAssertEqual(collapsedScroll.verticalScroller.map { String(reflecting: type(of: $0)) }, initialScrollerClass)
        XCTAssertEqual(collapsedScroll.verticalScroller?.isHidden, initialScrollerHidden)
        XCTAssertEqual(collapsedScroll.verticalScroller?.isEnabled, initialScrollerEnabled)
        XCTAssertEqual(collapsedScroll.hasVerticalScroller, initialHasVerticalScroller)
        XCTAssertEqual(collapsedScroll.autohidesScrollers, initialAutohidesScrollers)
        XCTAssertEqual(collapsedScroll.frame.width, initialFrameSize.width, accuracy: 0.5)
        XCTAssertEqual(collapsedScroll.frame.height, initialFrameSize.height, accuracy: 0.5)
        XCTAssertEqual(collapsedScroll.contentView.bounds.width, initialClipSize.width, accuracy: 0.5)
        XCTAssertEqual(collapsedScroll.contentView.bounds.height, initialClipSize.height, accuracy: 0.5)
        if let collapsedDocument = collapsedScroll.documentView {
            XCTAssertNil(findLastAgent(in: collapsedDocument))
        }
        var short = refreshed
        short.codexAgents = Array(agents.prefix(1))
        short.codexAgentCount = 1
        store.testReplacePreviewTasks([short])
        store.toggleCodexGroup(task.id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        let shortViews = scrollViews(in: hosting)
        XCTAssertEqual(shortViews.count, 1)
        let shortScroll = try XCTUnwrap(shortViews.first)
        XCTAssertEqual(shortScroll.scrollerStyle, .legacy)
        if let shortIndicator = shortScroll.verticalScroller {
            XCTAssertFalse(!shortIndicator.isHidden && shortIndicator.isEnabled && shortIndicator.knobProportion < 1,
                           "The scrollbar must not draw a knob when the content fits")
        }
    }

    @MainActor
    func testScrollerDismantleDoesNotReapplyQueuedStyleChange() throws {
        guard ProcessInfo.processInfo.environment["AITM_SYNTHETIC_REQUIRED"] == "1" else {
            throw XCTSkip("Requires the isolated hosted runner")
        }
        _ = try claudeSyntheticDirectory(prefix: "aitm-agent-detach-")
        NSApplication.shared.setActivationPolicy(.prohibited)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .overlay
        let probe = OverlayScrollerProbe.Probe(frame: .zero, alwaysVisible: false, restoresOriginalScroller: true)
        document.addSubview(probe)
        probe.configure()
        let original = try XCTUnwrap(scroll.verticalScroller)
        let originalStyle = scroll.scrollerStyle
        let originalHasScroller = scroll.hasVerticalScroller
        let originalAutohides = scroll.autohidesScrollers
        XCTAssertEqual(originalStyle, .overlay)
        probe.alwaysVisible = true
        probe.configure()
        XCTAssertEqual(scroll.scrollerStyle, .legacy)
        XCTAssertTrue(scroll.verticalScroller is OverlayScrollerProbe.TracklessScroller)
        OverlayScrollerProbe.dismantleNSView(probe, coordinator: ())
        let queueDrained = expectation(description: "queued scroller observation has run")
        DispatchQueue.main.async { queueDrained.fulfill() }
        wait(for: [queueDrained], timeout: 3)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(scroll.verticalScroller === original)
        XCTAssertEqual(scroll.scrollerStyle, originalStyle)
        XCTAssertEqual(scroll.hasVerticalScroller, originalHasScroller)
        XCTAssertEqual(scroll.autohidesScrollers, originalAutohides)
        probe.removeFromSuperview()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(scroll.verticalScroller === original)
        XCTAssertEqual(scroll.scrollerStyle, originalStyle)
    }
    #endif

    @MainActor
    func testRenderSyntheticGroupedParent() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted",
              env["RUNNER_OS"] == "macOS", env["AITM_MACOS_TEST_SANDBOX"] == "1",
              let rootPath = env["AITM_SYNTHETIC_TEST_ROOT"], let denied = env["AITM_CI_DENIED_FILE"],
              env["HOME"] == nil, env["CODEX_HOME"] == nil else {
            if env["AITM_SYNTHETIC_REQUIRED"] == "1" { throw CocoaError(.fileWriteNoPermission) }
            throw XCTSkip("Synthetic renders require the isolated hosted runner")
        }
        let probe = denied.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        if probe >= 0 { Darwin.close(probe); throw CocoaError(.fileReadNoPermission) }
        guard errno == EACCES || errno == EPERM else { throw CocoaError(.fileReadNoPermission) }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        let runnerTemp = URL(fileURLWithPath: "/Users/runner/work/_temp", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let parent = resolved.deletingLastPathComponent()
        guard root == resolved, resolved.lastPathComponent == "temp",
              parent.lastPathComponent.hasPrefix("aitm-card-tests."),
              parent.deletingLastPathComponent() == runnerTemp else { throw CocoaError(.fileWriteNoPermission) }
        let output = resolved.appendingPathComponent("grouping-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { AppLanguage.previewOverride = nil }
        let rootID = "019127f4-35ae-7c73-9e72-a10123456789"
        let ids = ["019127f4-35ae-7c73-9e72-a10123456780", "019127f4-35ae-7c73-9e72-a10123456781",
                   "019127f4-35ae-7c73-9e72-a10123456782"]
        for language in [AppLanguage.ru, .en] {
            AppLanguage.previewOverride = language
            for dark in [false, true] {
                for compact in [false, true] {
                  for disclosureOpen in [false, true] {
                   let scenarios = ["normal", "long", "demo", "unavailable", "no-active", "percent", "count-unknown", "both-unknown"] +
                    (compact ? [] : ["plan-unconfirmed", "task-unconfirmed", "many-agents"])
                   for scenario in scenarios {
                    for selected in (compact && scenario == "demo" ? [0, 1] : [0]) {
                    if selected == 1 && disclosureOpen { continue }
                    if scenario == "unavailable" && disclosureOpen { continue }
                    let demo = scenario == "demo"
                    let title = scenario == "long"
                        ? tr("Очень длинное название родительской задачи для проверки обрезки и подсказки",
                             "A very long parent task title for checking truncation and its tooltip")
                        : tr("Проверка загрузки событий", "Checking event loading")
                    let parentTask = MonitoredTask(id: rootID, provider: .codex, title: title,
                        activity: demo ? tr("Проверяю обработку событий", "Checking event processing") :
                            tr("Проверяю сохранение основного действия", "Checking that the parent activity stays visible"),
                        isActive: true, progress: 50, progressKind: .exact,
                        steps: demo ? [TaskStep(title: tr("Изучить обработку событий", "Review event processing"), status: .done),
                                       TaskStep(title: tr("Проверить загрузку данных", "Check data loading"), status: .done),
                                       TaskStep(title: tr("Проверить обработку ошибок", "Check error handling"), status: .active),
                                       TaskStep(title: tr("Сравнить результаты", "Compare results"), status: .pending)] :
                            [TaskStep(title: tr("Первый этап", "First step"), status: .done),
                             TaskStep(title: scenario == "long"
                                ? tr("Очень длинное название активного этапа для проверки подсказки и счётчика помощников",
                                     "A very long active step title for checking its tooltip and assistant count")
                                : tr("Второй этап", "Second step"), status: scenario == "no-active" ? .pending : .active)],
                        updatedAt: Date(), isUnconfirmed: scenario == "task-unconfirmed",
                        planConfirmed: scenario != "plan-unconfirmed", progressBasis: scenario == "percent" ? .task : .steps)
                    let agentNames = ["Curie", "Averroes", "Noether"]
                    let exampleActions = [tr("Проверка обработки ошибок", "Checking error handling"),
                                          tr("Проверка загрузки данных", "Checking data loading"),
                                          tr("Сравнение результатов проверок", "Comparing check results")]
                    let children = ids.enumerated().map { offset, id in
                        MonitoredTask(id: id, provider: .codex,
                            title: demo ? agentNames[offset] : tr("Помощник \(offset + 1)", "Assistant \(offset + 1)"),
                            activity: tr("Статус не подтверждён", "Status unconfirmed"), isActive: false, progress: nil,
                            progressKind: .none, steps: [], updatedAt: Date(), isUnconfirmed: true,
                            lastKnownActivity: demo ? exampleActions[offset] :
                                tr("Проверенное действие \(offset + 1)", "Observed action \(offset + 1)"),
                            lastActivityIdentityConfirmed: true)
                    }
                    let unavailable = MonitoredTask(id: rootID, provider: .codex, title: tr("Проверка загрузки событий", "Checking event loading"),
                        activity: tr("Статус не подтверждён", "Status unconfirmed"), isActive: false, progress: nil,
                        progressKind: .none, steps: [], updatedAt: Date(), isUnconfirmed: true,
                        lastKnownActivity: tr("Проверка обработки ошибок", "Checking error handling"),
                        lastActivityIdentityConfirmed: true)
                    var grouped = scenario == "unavailable" ? [unavailable] : CodexTaskGrouping.project([parentTask] + children,
                        parents: [ids[0]: rootID, ids[1]: rootID, ids[2]: ids[0]], titles: [rootID: title], confirmedRoots: [rootID])
                    if scenario == "many-agents" {
                        let more = (4...9).map { number in
                            CodexAgentDetail(id: "extra-\(number)", title: tr("Помощник \(number)", "Assistant \(number)"),
                                             activity: tr("Проверенное действие \(number)", "Observed action \(number)"),
                                             isActive: false, isUnconfirmed: true)
                        }
                        grouped[0].codexAgents = (grouped[0].codexAgents ?? []) + more
                        grouped[0].codexAgentCount = grouped[0].codexAgents?.count
                    }
                    if scenario == "count-unknown" || scenario == "both-unknown" {
                        grouped[0].codexAgentCountUnconfirmed = true
                        if scenario == "count-unknown" { grouped[0].codexAgentsUnconfirmed = false }
                    }
                    let item = try XCTUnwrap(grouped.first)
                    XCTAssertEqual(grouped.count, 1)
                    if scenario == "unavailable" {
                        XCTAssertTrue(item.displayedActivity.contains(tr("Последнее:", "Last:")))
                    } else {
                        XCTAssertEqual(item.codexAgentCount, scenario == "many-agents" ? 9 : 3)
                        XCTAssertEqual(item.title, title)
                        XCTAssertEqual(item.progress, parentTask.progress)
                        XCTAssertEqual(item.codexAgents?.count, scenario == "many-agents" ? 9 : 3)
                        XCTAssertEqual(item.codexAgentCountAtTitle,
                                       ["no-active", "plan-unconfirmed", "task-unconfirmed"].contains(scenario))
                        if scenario == "percent" {
                            XCTAssertEqual(item.compactProgressLabel, "50%")
                            XCTAssertNotNil(item.compactExtraAgentStepLabel)
                        }
                        XCTAssertEqual(item.codexAgents?.first?.activity,
                                       demo ? exampleActions[0] : tr("Проверенное действие 1", "Observed action 1"))
                    }
                    let claude = MonitoredTask(id: "claude:synthetic", provider: .claude,
                        title: tr("Обновить настройки уведомлений", "Update notification settings"),
                        activity: tr("Проверяю работу уведомлений", "Checking notifications"),
                        isActive: true, progress: nil, progressKind: .none, steps: [], updatedAt: Date())
                    let store = TaskStore(codexReader: CodexTaskReader(codexHome: resolved.appendingPathComponent("missing-codex")),
                                          claudeReader: ClaudeTaskReader(eventFile: resolved.appendingPathComponent("missing-claude")),
                                          previewTasks: demo ? grouped + [claude] : grouped)
                    store.isCompact = compact
                    store.compactIndex = selected
                    if disclosureOpen { store.toggleCodexGroup(rootID) }
                    XCTAssertEqual(store.isCodexGroupExpanded(rootID), disclosureOpen)
                    XCTAssertEqual(store.count(for: .all), demo ? 2 : 1)
                    XCTAssertEqual(store.tasks[selected].provider, selected == 1 ? .claude : .codex)
                    let size = compact ? NSSize(width: 372, height: 182) : NSSize(width: 560, height: 700)
                    let view = RootView().environmentObject(store).environment(\.colorScheme, dark ? .dark : .light)
                    let hosting = NSHostingView(rootView: view)
                    hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    hosting.frame = NSRect(origin: .zero, size: size)
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = hosting
                    window.orderFrontRegardless()
                    hosting.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                    hosting.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let name = "grouped-\(language.rawValue)-\(dark ? "dark" : "light")-\(compact ? "compact" : "expanded")-\(disclosureOpen ? "open" : "closed")-\(scenario)-\(selected == 1 ? "claude" : "codex").png"
                    let destination = output.appendingPathComponent(name).path
                    guard destination.hasPrefix(output.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
                    let descriptor = destination.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
                    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
                    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    try handle.write(contentsOf: bytes)
                    try handle.close()
                    window.close()
                    }
                   }
                  }
                }
            }
        }
    }
}
