using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using AITaskMonitor.Prototype;

internal static class Program
{
    private static int checks;

    [STAThread]
    private static int Main()
    {
        try
        {
            var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            foreach (string language in new[] { "ru", "en" })
                foreach (string theme in new[] { "dark", "light" })
                    foreach (string scene in SyntheticProviderScenarios.Names)
                        CheckScenario(scene, language, theme);
            CheckSelection();
            CheckLegacyDemoLanguage();
            CheckExternalTaskText();
            foreach (string language in new[] { "ru", "en" })
                foreach (string theme in new[] { "dark", "light" })
                {
                    CheckClaudeFlow(language, theme);
                    CheckClaudeActiveUnconfirmedPlan(language, theme);
                    CheckVisibleTabCounts(language, theme);
                    CheckClaudeContradictoryState(language, theme);
                }
            CheckClaudeCorrections();
            CheckStepCountWords();
            string? configuredContourReference = Environment.GetEnvironmentVariable("AITM_MAC_CONTOUR_REFERENCE");
            string contourReference = string.IsNullOrEmpty(configuredContourReference)
                ? Path.Combine(AppContext.BaseDirectory, "Fixtures", "macos-tab-paths.json")
                : configuredContourReference;
            ContourChecks.Run(contourReference);
            string? captureDirectory = Environment.GetEnvironmentVariable("AITM_TAB_CAPTURE_DIRECTORY");
            if (!string.IsNullOrEmpty(captureDirectory)) CaptureTabStates(captureDirectory);
            application.Shutdown();
            Console.WriteLine($"Synthetic event-to-state-to-WPF checks passed: {checks} assertions.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }

    private static void CheckClaudeContradictoryState(string language, string theme)
    {
        var (window, controller) = Open("active", language, theme);
        try
        {
            SampleTask confirmed = controller.CurrentTasks.Single(item => item.Provider == "claude");
            SampleTask codex = controller.CurrentTasks.Single(item => item.Provider == "codex");
            var update = typeof(PrototypeWindow).GetMethod("UpdateSamples", BindingFlags.Instance | BindingFlags.NonPublic)!;
            var render = typeof(PrototypeWindow).GetMethod("Render", BindingFlags.Instance | BindingFlags.NonPublic)!;
            foreach (SampleTask control in new[] { confirmed, codex })
            {
                update.Invoke(controller, [new List<SampleTask> { control }]);
                render.Invoke(controller, null);
                window.UpdateLayout();
                Check(Visible<ProgressBar>(window).Any() && Visible<Border>(window).Any(border =>
                    border.Width == 14 && border.Height == 14 && border.Child is not null),
                    "A confirmed task lost its progress or completed-step marker.");
            }
            SampleTask task = confirmed with
            {
                Status = "unknown",
                PlanConfirmed = true,
                Activity = language == "en" ? "Status unconfirmed" : "Статус не подтверждён"
            };
            update.Invoke(controller, [new List<SampleTask> { task }]);
            render.Invoke(controller, null);
            window.UpdateLayout();
            string note = language == "en" ? "Plan unconfirmed" : "План не подтверждён";
            Check(Visible<TextBlock>(window).Any(text => text.Text.StartsWith(note, StringComparison.Ordinal)), "Unconfirmed Claude plan note is missing.");
            var texts = Visible<TextBlock>(window).Select(text => text.Text).ToHashSet(StringComparer.Ordinal);
            Check(task.Steps.All(step => texts.Contains(step.Title)), "Unconfirmed Claude plan lost a known step name.");
            Check(!Visible<ProgressBar>(window).Any(), "Unconfirmed Claude task showed a progress bar.");
            var markers = Visible<Border>(window).Where(border => border.Width == 14 && border.Height == 14).ToArray();
            Check(markers.Length > 0 && markers.All(marker => marker.Child is null && marker.BorderThickness.Left == 1),
                "Unconfirmed Claude task displayed confirmed step markers.");
            Click((Button)window.FindName("MinimizeButton"));
            window.UpdateLayout();
            Check(Visible<TextBlock>(window).Any(text => text.Text == note) && !Visible<ProgressBar>(window).Any(),
                "Compact unconfirmed Claude state differs.");
        }
        finally { window.Close(); }
    }

    private static void CheckVisibleTabCounts(string language, string theme)
    {
        var (window, controller) = Open("active", language, theme);
        try
        {
            SampleTask codex = controller.CurrentTasks.Single(task => task.Provider == "codex");
            SampleTask claude = controller.CurrentTasks.Single(task => task.Provider == "claude");
            bool english = language == "en";
            string codexActive = english ? "Example Codex task" : "Пример задачи Codex";
            string codexUnknown = english ? "Unconfirmed Codex task" : "Неподтверждённая задача Codex";
            string claudeUnknown = english ? "Unconfirmed Claude task" : "Неподтверждённая задача Claude";
            string claudeOther = english ? "Another Claude task" : "Другая задача Claude";
            string waitingTitle = english ? "DeepSeek task awaiting confirmation" : "Задача DeepSeek ожидает подтверждения";
            string unconfirmed = english ? "Status unconfirmed" : "Статус не подтверждён";
            string waiting = english ? "Waiting for confirmation" : "Ожидает подтверждения";
            var tasks = new List<SampleTask>
            {
                codex with { Title = codexActive },
                codex with { Id = "codex:unknown", Title = codexUnknown, Activity = unconfirmed, Status = "unknown", Progress = null,
                    PlanConfirmed = false, Steps = codex.Steps.Select(step => step with { Status = "unknown" }).ToArray() },
                claude with { Title = claudeUnknown, Activity = unconfirmed, Status = "unknown", Progress = null,
                    PlanConfirmed = false, Steps = claude.Steps.Select(step => step with { Status = "unknown" }).ToArray() },
                claude with { Id = "claude:second", Title = claudeOther, Activity = unconfirmed, Status = "unknown", Progress = null,
                    PlanConfirmed = false, Steps = claude.Steps.Select(step => step with { Status = "unknown" }).ToArray() }
            };
            var update = typeof(PrototypeWindow).GetMethod("UpdateSamples", BindingFlags.Instance | BindingFlags.NonPublic)!;
            var render = typeof(PrototypeWindow).GetMethod("Render", BindingFlags.Instance | BindingFlags.NonPublic)!;
            update.Invoke(controller, [tasks]);
            render.Invoke(controller, null);
            window.UpdateLayout();
            AssertTabs(4, 2, 2);
            string? captureDirectory = Environment.GetEnvironmentVariable("AITM_TAB_COUNT_CAPTURE_DIRECTORY");
            if (!string.IsNullOrEmpty(captureDirectory))
            {
                Directory.CreateDirectory(captureDirectory);
                SaveCapture(window, Path.Combine(captureDirectory, $"{theme}-{language}-visible-counts-all.png"));
            }
            Click(Tab("claude"));
            window.UpdateLayout();
            var texts = Visible<TextBlock>(window).Select(item => item.Text).ToHashSet(StringComparer.Ordinal);
            Check(texts.Contains(claudeUnknown) && texts.Contains(claudeOther) &&
                  !texts.Contains(codexActive) && !texts.Contains(codexUnknown),
                "The provider filter does not match its visible count.");
            AssertTabs(4, 2, 2);
            if (!string.IsNullOrEmpty(captureDirectory))
                SaveCapture(window, Path.Combine(captureDirectory, $"{theme}-{language}-visible-counts-claude.png"));
            tasks.RemoveAt(3);
            update.Invoke(controller, [tasks]);
            render.Invoke(controller, null);
            window.UpdateLayout();
            AssertTabs(3, 2, 1);
            tasks.Add(codex with { Id = "deepseek:waiting", Provider = "deepseek", ProviderName = "DeepSeek Harness",
                Title = waitingTitle, Activity = waiting, Status = "waiting", Progress = null, PlanConfirmed = false, Steps = [] });
            update.Invoke(controller, [tasks]);
            render.Invoke(controller, null);
            window.UpdateLayout();
            AssertTabs(4, 2, 1, 1);
            Click(Tab("deepseek"));
            window.UpdateLayout();
            Check(Visible<TextBlock>(window).Any(text => text.Text == waitingTitle), "Waiting task is missing from its provider filter.");
            if (!string.IsNullOrEmpty(captureDirectory))
                SaveCapture(window, Path.Combine(captureDirectory, $"{theme}-{language}-visible-counts-deepseek.png"));

            Button Tab(string id) => ((StackPanel)window.FindName("ProviderTabsPanel")).Children.OfType<Button>()
                .Single(button => (string)button.Tag == id);
            void AssertTabs(int all, int codexCount, int claudeCount, int? deepSeekCount = null)
            {
                string lead = language == "en" ? "Show tasks: " : "Показать задачи: ";
                foreach (var item in new[] { (Id: "all", Label: language == "en" ? "All" : "Все", Count: all),
                    (Id: "codex", Label: "Codex", Count: codexCount), (Id: "claude", Label: "Claude Code", Count: claudeCount) })
                {
                    Button tab = Tab(item.Id);
                    Check(AutomationProperties.GetName(tab) == $"{lead}{item.Label}, {item.Count}", "Accessible tab count differs from visible cards.");
                    Check(Visible<TextBlock>(tab).Any(text => text.Text == item.Count.ToString()), "Displayed tab count differs from visible cards.");
                }
                if (deepSeekCount.HasValue)
                {
                    Button deepSeek = Tab("deepseek");
                    Check(AutomationProperties.GetName(deepSeek) == $"{lead}DeepSeek Harness, {deepSeekCount.Value}" &&
                          Visible<TextBlock>(deepSeek).Any(text => text.Text == deepSeekCount.Value.ToString()),
                        "A waiting task was omitted from its provider count.");
                }
            }
        }
        finally { window.Close(); }
    }

    private static void CheckClaudeActiveUnconfirmedPlan(string language, string theme)
    {
        DateTime start = new(2026, 11, 5, 15, 9, 0, DateTimeKind.Utc);
        const string begin = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:00Z","event":"UserPromptSubmit","active":true}""";
        const string create = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:10Z","event":"TaskCreated","active":true,"task_id":"one","task_subject":"Synthetic step"}""";
        const string laterWrittenPrompt = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:09Z","event":"UserPromptSubmit","active":true}""";
        var source = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, create, laterWrittenPrompt), "", start.AddSeconds(12), start).Single();
        var task = ClaudePresentation.Map(source, language);
        Check(task.Active && !task.PlanConfirmed && task.Progress is null, "An active task with an uncertain plan was not retained correctly.");
        var (window, controller) = Open("empty", language, theme);
        try
        {
            typeof(PrototypeWindow).GetMethod("UpdateSamples", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(controller, [new List<SampleTask> { task }]);
            typeof(PrototypeWindow).GetMethod("Render", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(controller, null);
            window.UpdateLayout();
            string note = language == "en" ? "Plan unconfirmed" : "План не подтверждён";
            Check(Visible<TextBlock>(window).Any(text => text.Text.StartsWith(note, StringComparison.Ordinal)), "The active task's plan note is missing.");
            Check(!Visible<ProgressBar>(window).Any(), "An active task's uncertain plan showed a bar.");
            string? captures = Environment.GetEnvironmentVariable("AITM_CLAUDE_CAPTURE_DIRECTORY");
            if (!string.IsNullOrEmpty(captures)) SaveCapture(window, Path.Combine(captures, $"{theme}-{language}-active-unconfirmed.png"));
            Click((Button)window.FindName("MinimizeButton"));
            window.UpdateLayout();
            Check(Visible<TextBlock>(window).Any(text => text.Text == note) && !Visible<ProgressBar>(window).Any(), "The compact uncertain-plan state differs.");
            if (!string.IsNullOrEmpty(captures)) SaveCapture(window, Path.Combine(captures, $"{theme}-{language}-active-unconfirmed-compact.png"));
        }
        finally { window.Close(); }
    }

    private static void CheckClaudeFlow(string language, string theme)
    {
        bool english = language == "en";
        Check(Options.TryParse(["--scene", "claude-synthetic"], out _), "Synthetic Claude scene is not selectable.");
        var (window, controller) = Open("claude-synthetic", language, theme);
        try
        {
            SampleTask task = controller.CurrentTasks.Single();
            Check(task.Provider == "claude" && task.Active && task.PlanConfirmed, "Claude start did not become active.");
            Check(task.Id == "claude:synthetic" && task.Progress == 0 && task.Steps.Length == 2, "Claude task or plan differs.");
            Check(task.Steps[0].Title == "Мой реальный этап", "A source-provided step was translated.");
            Check(task.Steps[1].Title == "Второй реальный этап", "A second source-provided step was translated.");
            var texts = Visible<TextBlock>(window).Select(text => text.Text).ToArray();
            Check(texts.Contains(task.Title) && texts.Contains("Мой реальный этап"), "Claude task was not rendered.");
            Check(texts.Contains(english ? "Step 2 of 2" : "Этап 2 из 2"), "Current Claude step was not rendered.");
            string note = english ? "Based on observed steps; may be inaccurate" : "По известным этапам, возможна неточность";
            Check(texts.Any(text => text.StartsWith(note, StringComparison.Ordinal)), "The observed-step qualification is missing.");
            Click((Button)window.FindName("MinimizeButton"));
            window.UpdateLayout();
            Check(Visible<TextBlock>(window).Any(text => text.Text == note), "The compact observed-step qualification is missing.");
            Click((Button)window.FindName("ExpandButton"));
            window.UpdateLayout();

            controller.AdvanceClaudeForTest();
            task = controller.CurrentTasks.Single();
            Check(task.Progress == 50 && task.Steps[0].Status == "done", "Completed Claude step did not update progress.");
            Check(task.Activity == (english ? "Completed: TaskUpdate" : "Завершено: TaskUpdate"), "Observed update activity was not rendered correctly.");
            controller.AdvanceClaudeForTest();
            task = controller.CurrentTasks.Single();
            Check(task.Activity == (english ? "Completed: Мой инструмент" : "Завершено: Мой инструмент"), "Tool activity changed source text.");
            window.UpdateLayout();
            texts = Visible<TextBlock>(window).Select(text => text.Text).ToArray();
            Check(texts.Contains(task.Activity), "Updated Claude activity was not rendered.");

            controller.AdvanceClaudeForTest();
            task = controller.CurrentTasks.Single();
            Check(!task.Active && task.Status == "unknown", "Stale Claude status remained active.");
            Check(!task.PlanConfirmed && task.Progress is null, "Stale Claude plan remained confirmed.");
            window.UpdateLayout();
            texts = Visible<TextBlock>(window).Select(text => text.Text).ToArray();
            Check(texts.Contains(english ? "Status unconfirmed" : "Статус не подтверждён"), "Unconfirmed Claude state was not rendered.");
            Check(texts.Any(text => text.StartsWith(english ? "Plan unconfirmed · 2 steps" : "План не подтверждён · 2 этапа", StringComparison.Ordinal)), "Unconfirmed plan label was not rendered.");
            Check(!Visible<ProgressBar>(window).Any(), "Unconfirmed Claude task showed a progress bar.");
            var markers = Visible<Border>(window).Where(border => border.Width == 14 && border.Height == 14).ToArray();
            Check(markers.Length == 2 && markers.All(marker => marker.Child is null && marker.BorderThickness.Left == 1),
                  "Unconfirmed Claude plan displayed confirmed step markers.");
            string? captures = Environment.GetEnvironmentVariable("AITM_CLAUDE_CAPTURE_DIRECTORY");
            if (!string.IsNullOrEmpty(captures)) SaveCapture(window, Path.Combine(captures, $"{theme}-{language}-unconfirmed.png"));
            Check(!texts.Contains(english ? "Step 2 of 2" : "Этап 2 из 2"), "Unconfirmed Claude task claimed a current step.");
            Click((Button)window.FindName("MinimizeButton"));
            window.UpdateLayout();
            Check(Visible<TextBlock>(window).Any(text => text.Text == (english ? "Plan unconfirmed" : "План не подтверждён")), "Compact unconfirmed plan label is missing.");
            Check(!Visible<ProgressBar>(window).Any(), "Compact unconfirmed Claude task showed a progress bar.");
            if (!string.IsNullOrEmpty(captures)) SaveCapture(window, Path.Combine(captures, $"{theme}-{language}-compact-unconfirmed.png"));
            Click((Button)window.FindName("ExpandButton"));
            window.UpdateLayout();
            controller.AdvanceClaudeForTest();
            Check(controller.CurrentTasks.Count == 0, "Completed Claude task remained visible.");
            window.UpdateLayout();
            texts = Visible<TextBlock>(window).Select(text => text.Text).ToArray();
            Check(texts.Contains(english ? "No active tasks" : "Активных задач сейчас нет"), "Empty state was not restored.");
        }
        finally { window.Close(); }
    }

    private static void CheckClaudeCorrections()
    {
        DateTime start = new(2026, 11, 5, 15, 9, 0, DateTimeKind.Utc);
        const string begin = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:00Z","event":"UserPromptSubmit","active":true}""";
        const string create = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:01Z","event":"TaskCreated","active":true,"task_id":"old","task_subject":"Старый этап","task_status":"pending"}""";
        const string done = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:02Z","event":"TaskCompleted","active":true,"task_id":"old","task_status":"completed"}""";
        const string stop = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:03Z","event":"Stop","active":false}""";
        const string next = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:04Z","event":"UserPromptSubmit","active":true}""";
        foreach (bool stopped in new[] { false, true })
        {
            string log = string.Join("\n", stopped ? new[] { begin, create, done, stop, next } : new[] { begin, create, done, next });
            var parsed = AITaskMonitor.Claude.Reader.Read(log, "", start.AddSeconds(5), start).Single();
            var mapped = ClaudePresentation.Map(parsed, "en");
            Check(parsed.Unconfirmed == stopped && !parsed.PlanConfirmed && !mapped.PlanConfirmed && mapped.Progress is null,
                  "An old plan or an unverified stop was treated as confirmed for a new request.");
            Check(mapped.Steps.Single().Title == "Старый этап", "Previous step was not retained as history.");
        }
        const string another = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:05Z","event":"TaskCreated","active":true,"task_id":"new","task_subject":"Новый этап"}""";
        var partial = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, create, done, stop, next, another), "", start.AddSeconds(6), start).Single();
        Check(!partial.PlanConfirmed && partial.Steps.Length == 2, "One new task incorrectly confirmed a retained prior plan.");
        const string noTitle = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:01Z","event":"TaskCreated","active":true,"task_id":"7"}""";
        const string titleLater = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:02Z","event":"TaskCompleted","active":true,"task_id":"7","task_subject":"Новый реальный текст"}""";
        var generated = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, noTitle), "", start.AddSeconds(2), start).Single();
        Check(!generated.PlanConfirmed && ClaudePresentation.Map(generated, "en").Steps.Single().Title == "Step 7" &&
              ClaudePresentation.Map(generated, "ru").Steps.Single().Title == "Этап 7", "An unconfirmed generated label was not localized.");
        var named = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, noTitle, titleLater), "", start.AddSeconds(3), start).Single();
        Check(named.Steps.Single().title == "Новый реальный текст" && !named.Steps.Single().generated,
              "Later source title did not replace the generated placeholder.");
        Check(ClaudePresentation.Map(named, "en").Steps.Single().Title == "Новый реальный текст", "Source title was translated.");

        const string future = """{"session_id":"synthetic","timestamp":"2026-11-06T15:09:00Z","event":"PreToolUse","active":true,"tool_name":"synthetic"}""";
        var ahead = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, create, future), "", start.AddMinutes(121), start).Single();
        Check(ahead.Unconfirmed && !ahead.PlanConfirmed && ClaudePresentation.Map(ahead, "en").Progress is null,
              "A future event remained confirmed.");
        const string laterStop = """{"session_id":"synthetic","timestamp":"2026-11-05T17:10:00Z","event":"Stop","active":false}""";
        foreach (DateTime now in new[] { start.AddMinutes(121), start.AddHours(25) })
        {
            var reordered = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, future, laterStop), "", now, start).Single();
            Check(reordered.Unconfirmed && !reordered.PlanConfirmed, "A future event hid a later stop and became confirmed.");
        }
        const string futureStop = """{"session_id":"synthetic","timestamp":"2026-11-06T15:09:00Z","event":"Stop","active":false}""";
        const string liveAfter = """{"session_id":"synthetic","timestamp":"2026-11-05T15:10:00Z","event":"PreToolUse","active":true}""";
        var hidden = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, futureStop), "", start.AddSeconds(1), start).Single();
        var hiddenAfterLive = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, futureStop, liveAfter), "", start.AddSeconds(61), start).Single();
        Check(hidden.Unconfirmed && hiddenAfterLive.Unconfirmed, "A future stop incorrectly hid a previously observed task.");
        const string nextSecondStop = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:01Z","event":"Stop","active":false}""";
        const string oneMinuteStop = """{"session_id":"synthetic","timestamp":"2026-11-05T15:10:00Z","event":"Stop","active":false}""";
        foreach (string upcoming in new[] { nextSecondStop, oneMinuteStop })
        {
            var futureTerminal = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, upcoming), "", start, start).Single();
            Check(futureTerminal.Unconfirmed, "A future stop within clock tolerance hid a task.");
        }
        const string activeAtTwelve = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:12Z","event":"PreToolUse","active":true}""";
        const string stopAtTen = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:10Z","event":"Stop","active":false}""";
        var reversedTerminal = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, activeAtTwelve, stopAtTen), "", start.AddSeconds(13), start).Single();
        Check(reversedTerminal.Unconfirmed, "A reversed terminal inside the clock tolerance became confirmed.");
        const string stopAtTwelve = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:12Z","event":"Stop","active":false}""";
        const string activeAtEleven = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:11Z","event":"PreToolUse","active":true}""";
        var equalThenReversed = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, activeAtTwelve, stopAtTwelve, activeAtEleven), "", start.AddSeconds(13), start).Single();
        Check(equalThenReversed.Unconfirmed, "An equal-time stop followed by reversed activity hid the task.");
        var equalLegacyActive = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, stopAtTwelve), activeAtTwelve, start.AddSeconds(13), start).Single();
        var equalCurrentActive = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, activeAtTwelve), stopAtTwelve, start.AddSeconds(13), start).Single();
        Check(equalLegacyActive.Unconfirmed && equalCurrentActive.Unconfirmed, "Opposite equal-time file states were treated as ordered.");
        const string activeAfterTwelve = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:13Z","event":"PreToolUse","active":true}""";
        var maskedEqualActive = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, activeAtTwelve, activeAfterTwelve), stopAtTwelve, start.AddSeconds(14), start).Single();
        Check(maskedEqualActive.Unconfirmed, "A later active event hid an equal-time cross-file conflict.");
        const string stopAtFourteen = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:14Z","event":"Stop","active":false}""";
        const string neutralAtFifteen = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:15Z","event":"Notice"}""";
        const string activeAtThirteen = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:13Z","event":"PreToolUse","active":true}""";
        var afterNeutral = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, stopAtFourteen, neutralAtFifteen, activeAtThirteen), "", start.AddSeconds(16), start).Single();
        Check(afterNeutral.Unconfirmed, "Neutral events hid an active-state ordering conflict.");
        const string clearStopAtFourteen = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:14Z","event":"Stop","active":false,"stage_phase":"stop_clear","stage_version":1}""";
        var crossNeutral = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, clearStopAtFourteen, neutralAtFifteen), activeAtThirteen, start.AddSeconds(16), start);
        Check(crossNeutral.Length == 0, "Clearly earlier legacy activity changed a current terminal event.");
        const string legacyBetween = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:14.500Z","event":"PreToolUse","active":true}""";
        var crossNeutralConflict = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, stopAtFourteen, neutralAtFifteen), legacyBetween, start.AddSeconds(16), start).Single();
        Check(crossNeutralConflict.Unconfirmed, "Neutral current event hid a cross-file status conflict.");
        var near = AITaskMonitor.Claude.Reader.Read(begin, "", start.AddSeconds(-60), DateTime.MinValue).Single();
        var beyond = AITaskMonitor.Claude.Reader.Read(begin, "", start.AddSeconds(-61), DateTime.MinValue).Single();
        Check(!near.Unconfirmed && beyond.Unconfirmed, "Future clock tolerance boundary changed.");
        var recent = AITaskMonitor.Claude.Reader.Read(begin, "", start.AddMinutes(120).AddSeconds(-1), start).Single();
        var stale = AITaskMonitor.Claude.Reader.Read(begin, "", start.AddMinutes(120), start).Single();
        Check(!recent.Unconfirmed && stale.Unconfirmed && !stale.PlanConfirmed, "Staleness boundary changed.");
        const string legacyOne = """{"session_id":"synthetic","timestamp":"2026-11-05T15:12:00Z","event":"TaskCreated","active":true,"task_id":"overlap","task_subject":"Шаг"}""";
        const string legacyTwo = """{"session_id":"synthetic","timestamp":"2026-11-05T15:13:00Z","event":"PostToolUse","active":true}""";
        const string currentLater = """{"session_id":"synthetic","timestamp":"2026-11-05T15:14:00Z","event":"PreToolUse","active":true}""";
        var overlap = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, currentLater), string.Join("\n", legacyOne, legacyTwo), start.AddMinutes(6), start).Single();
        Check(!overlap.Unconfirmed && !overlap.PlanConfirmed, "Ordered sources changed session certainty or confirmed a legacy plan.");
        const string legacyLater = """{"session_id":"synthetic","timestamp":"2026-11-05T15:11:00Z","event":"PreToolUse","active":true}""";
        const string currentStop = """{"session_id":"synthetic","timestamp":"2026-11-05T15:10:00Z","event":"Stop","active":false}""";
        const string currentEqual = """{"session_id":"synthetic","timestamp":"2026-11-05T15:11:00Z","event":"PreToolUse","active":true}""";
        var crossSource = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, currentEqual), legacyLater, start.AddSeconds(121), start).Single();
        Check(!crossSource.Unconfirmed, "Equal cross-source times must not be rejected.");
        var crossSourceUncertain = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, currentStop), legacyLater, start.AddSeconds(121), start).Single();
        Check(crossSourceUncertain.Unconfirmed && !crossSourceUncertain.PlanConfirmed, "An ambiguous later legacy event was confirmed after current Stop.");
        const string justLater = """{"session_id":"synthetic","timestamp":"2026-11-05T15:11:00.001Z","event":"PreToolUse","active":true}""";
        var crossSourceMillisecond = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, currentEqual), justLater, start.AddSeconds(121), start).Single();
        Check(crossSourceMillisecond.Unconfirmed, "A later legacy event was treated as current confirmation.");

        const string completedAtTen = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:10Z","event":"TaskCompleted","active":true,"task_id":"old","task_status":"completed"}""";
        const string inProgressAtNine = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:09Z","event":"PostToolUse","active":true,"task_id":"old","task_status":"in_progress"}""";
        const string inProgressAtTen = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:10Z","event":"PostToolUse","active":true,"task_id":"old","task_status":"in_progress"}""";
        const string createdAtTen = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:10Z","event":"TaskCreated","active":true,"task_id":"old","task_subject":"Шаг"}""";
        const string promptAtNine = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:09Z","event":"UserPromptSubmit","active":true}""";
        const string promptAtTen = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:10Z","event":"UserPromptSubmit","active":true}""";
        var orderedPlan = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, create, inProgressAtNine, completedAtTen), "", start.AddSeconds(12), start).Single();
        Check(!orderedPlan.PlanConfirmed && ClaudePresentation.Map(orderedPlan, "en").Progress is null, "Legacy step notices were treated as confirmed results.");
        var reversedStep = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, create, completedAtTen, inProgressAtNine), "", start.AddSeconds(12), start).Single();
        Check(!reversedStep.Unconfirmed && !reversedStep.PlanConfirmed && ClaudePresentation.Map(reversedStep, "en").Progress is null, "Reordered step was confirmed.");
        var reversedPrompt = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, createdAtTen, promptAtNine), "", start.AddSeconds(12), start).Single();
        Check(!reversedPrompt.Unconfirmed && !reversedPrompt.PlanConfirmed, "Reordered prompt confirmed a prior plan.");
        var crossStep = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, inProgressAtTen, neutralAtFifteen), completedAtTen, start.AddSeconds(16), start).Single();
        Check(!crossStep.Unconfirmed && !crossStep.PlanConfirmed && ClaudePresentation.Map(crossStep, "en").Progress is null, "Equal-time cross-file step conflict was confirmed.");
        var crossReversed = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, inProgressAtNine, neutralAtFifteen), completedAtTen, start.AddSeconds(16), start).Single();
        Check(!crossReversed.Unconfirmed && !crossReversed.PlanConfirmed, "A later legacy step remained confirmed.");
        const string neutralStepAtEleven = """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:11Z","event":"PostToolUse","active":true,"task_id":"old"}""";
        var maskedEqualConflict = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, inProgressAtTen, neutralStepAtEleven), completedAtTen, start.AddSeconds(12), start).Single();
        Check(!maskedEqualConflict.Unconfirmed && !maskedEqualConflict.PlanConfirmed, "A later neutral step hid an equal-time conflict.");
        var maskedReversedConflict = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, inProgressAtNine, neutralStepAtEleven), completedAtTen, start.AddSeconds(12), start).Single();
        Check(!maskedReversedConflict.Unconfirmed && !maskedReversedConflict.PlanConfirmed, "A later neutral step hid a reversed conflict.");
        var crossPrompt = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, promptAtTen), createdAtTen, start.AddSeconds(12), start).Single();
        Check(!crossPrompt.Unconfirmed && !crossPrompt.PlanConfirmed, "Equal-time prompt and step from separate files were treated as ordered.");
        var duplicatedStep = AITaskMonitor.Claude.Reader.Read(string.Join("\n", begin, completedAtTen), completedAtTen, start.AddSeconds(12), start).Single();
        Check(!duplicatedStep.Unconfirmed && !duplicatedStep.PlanConfirmed, "Duplicated legacy notices confirmed an unsupported plan.");
    }

    private static void CheckStepCountWords()
    {
        foreach (var (count, word) in new[] { (1,"этап"), (2,"этапа"), (4,"этапа"), (5,"этапов"),
                                               (11,"этапов"), (14,"этапов"), (21,"этап"), (22,"этапа"), (25,"этапов") })
            Check(PrototypeWindow.StepCountWord("ru", count) == word, "Russian step count form differs.");
        Check(PrototypeWindow.StepCountWord("en", 1) == "step" && PrototypeWindow.StepCountWord("en", 2) == "steps",
              "English step count form differs.");
    }

    private static void CheckScenario(string scene, string language, string theme)
    {
        bool english = language == "en";
        var fixture = new SyntheticProviderScenarios(scene);
        var snapshot = fixture.Snapshot();
        if (scene == "state-end") Check(snapshot.Length == 0, "Completed DeepSeek task remained visible.");
        else if (scene == "state-multi")
        {
            Check(snapshot.Length == 3, "Synthetic sessions collided.");
            Check(snapshot.Count(state => state.Session == "shared") == 2, "Different providers with the same session id collided.");
        }
        else
        {
            Check(snapshot.Length == 1, scene + ": expected one task.");
            string expected = scene switch
            {
                "state-kimi" or "state-unknown" or "state-gap" or "state-hermes-unknown" => "unknown",
                "state-wait" or "state-hermes-wait" => "waiting",
                _ => "active"
            };
            Check(snapshot[0].Status == expected, scene + ": unexpected state.");
            SampleTask mapped = ProviderPresentation.Map(snapshot[0], language);
            Check(mapped.Status == expected, scene + ": mapper changed the state.");
            if (scene == "state-kimi") Check(mapped.Progress is null && mapped.Steps.Length == 0, "Kimi acquired invented progress.");
            if (scene is "state-plan" or "state-wait" or "state-unknown" or "state-gap" or "state-old-plan")
            {
                Check(mapped.Progress == 50 && mapped.Steps.Length == 8, scene + ": plan progress changed.");
                Check(mapped.PlanConfirmed == (scene is not ("state-gap" or "state-old-plan")), scene + ": plan confirmation changed.");
            }
        }

        var (window, controller) = Open(scene, language, theme);
        try
        {
            var texts = Visible<TextBlock>(window).Select(text => text.Text).ToArray();
            if (scene == "state-end") Check(texts.Contains(english ? "No active tasks" : "Активных задач сейчас нет"), "Empty state text missing.");
            else if (scene == "state-multi")
                Check(controller.CurrentTasks.Select(task => task.Id).Distinct().Count() == 3, "Rendered task identities collided.");
            else
            {
                string? expectedText = scene switch
                {
                    "state-kimi" or "state-unknown" or "state-gap" or "state-hermes-unknown" => english ? "Status unconfirmed" : "Статус не подтверждён",
                    "state-wait" or "state-hermes-wait" => english ? "Waiting for confirmation" : "Ожидает подтверждения",
                    _ => english ? "Working" : "Выполняется"
                };
                Check(texts.Contains(expectedText), scene + ": expected state text not rendered.");
                string progress = english ? "Step 5 of 8" : "Этап 5 из 8";
                if (scene is "state-plan" or "state-wait") Check(texts.Contains(progress), scene + ": confirmed progress not rendered.");
                if (scene is "state-unknown" or "state-gap" or "state-old-plan") Check(!texts.Contains(progress), scene + ": unconfirmed progress was labelled as current.");
                if (scene is "state-gap" or "state-old-plan")
                {
                    Check(texts.Any(text => text.StartsWith(english ? "Plan unconfirmed · 8 steps" : "План не подтверждён · 8 этапов", StringComparison.Ordinal)), "Unconfirmed plan label missing.");
                    Check(Visible<ProgressBar>(window).Any(bar => bar.Value == 50), "The published retained-plan bar changed.");
                }
                if (scene == "state-kimi") Check(!Visible<ProgressBar>(window).Any(), "Kimi acquired a progress bar.");
            }
        }
        finally { window.Close(); }
    }

    private static void CheckSelection()
    {
        var (window, controller) = Open("state-multi", "en", "dark");
        try
        {
            Click((Button)window.FindName("MinimizeButton"));
            var dots = (StackPanel)window.FindName("CompactDotsPanel");
            Check(dots.Children.Count == 3, "Three independent compact tasks were not rendered.");
            Click((Button)dots.Children[2]);
            Check(controller.SelectedTaskId == "deepseek:shared", "The requested compact task was not selected.");
            controller.AdvanceMultiForTest();
            Check(controller.SelectedTaskId == "deepseek:shared", "An unrelated tool event changed the selection.");
            Click((Button)window.FindName("ExpandButton"));
            var tabs = (StackPanel)window.FindName("ProviderTabsPanel");
            Click(tabs.Children.OfType<Button>().Single(button => (string)button.Tag == "opencode"));
            Check(controller.SelectedProvider == "opencode", "The provider filter did not change.");
            Click((Button)window.FindName("MinimizeButton"));
            controller.AdvanceMultiForTest();
            Check(controller.SelectedTaskId == "deepseek:shared", "Removing another task changed the selection.");
            Check(controller.SelectedProvider == "all", "A removed provider left a stale filter.");
            controller.AdvanceMultiForTest();
            Check(controller.SelectedTaskId == "opencode:new", "A newly started task did not receive the published priority.");
            window.UpdateLayout();
            Check(Visible<TextBlock>(window).Any(text => text.Text == "OpenCode task"), "The newly selected task is not rendered.");
        }
        finally { window.Close(); }
    }

    private static void CheckLegacyDemoLanguage()
    {
        SampleTask[]? russian = null;
        foreach (string language in new[] { "ru", "en" })
        {
            var (window, controller) = Open("active", language, "light");
            try
            {
                var tasks = controller.CurrentTasks.ToArray();
                Check(tasks.Length == 2, "The demo must contain two tasks.");
                SampleTask codex = tasks.Single(task => task.Provider == "codex");
                SampleTask claude = tasks.Single(task => task.Provider == "claude");
                if (language == "ru")
                {
                    Check(codex.Title == "Создать индикатор прогресса задач" && claude.Title == "Задача Claude Code", "The Russian demo changed.");
                    russian = tasks;
                }
                else
                {
                    Check(codex.Title == "Create a task progress indicator" && claude.Title == "Claude Code task", "English demo titles were not translated.");
                    Check(codex.Activity.StartsWith("Checking plan cards", StringComparison.Ordinal) && claude.Activity == "Running visual checks", "English demo activity was not translated.");
                    Check(codex.Steps[0].Title == "Synchronize the task list" && claude.Steps[0].Title == "Check the local environment", "English demo steps were not translated.");
                    var texts = tasks.SelectMany(task => new[] { task.Title, task.Activity }.Concat(task.Steps.Select(step => step.Title)));
                    Check(!texts.Any(text => text.Any(ch => ch >= '\u0400' && ch <= '\u052f')), "English demo contains untranslated task text.");
                    Check(russian is not null && russian.Zip(tasks).All(pair => pair.First.Progress == pair.Second.Progress &&
                        pair.First.Status == pair.Second.Status && pair.First.Steps.Select(step => step.Status).SequenceEqual(pair.Second.Steps.Select(step => step.Status))),
                        "Translating demo text changed its state or progress.");
                    var rendered = Visible<TextBlock>(window).Select(text => text.Text).ToArray();
                    Check(rendered.Contains(codex.Title) && rendered.Contains(claude.Title), "English demo titles were not rendered.");
                }
            }
            finally { window.Close(); }
        }
    }

    private static void CheckExternalTaskText()
    {
        var (window, controller) = Open("active", "en", "dark");
        try
        {
            const string title = "Мой настоящий заголовок";
            const string activity = "Моё собственное описание";
            var tasks = controller.CurrentTasks.Select(task => task.Provider == "claude"
                ? task with { Title = title, Activity = activity, Steps = [new SampleStep("Мой этап", "active")] }
                : task).ToList();
            Type type = typeof(PrototypeWindow);
            type.GetField("samples", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(controller, tasks);
            type.GetMethod("Render", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(controller, null);
            window.UpdateLayout();
            var rendered = Visible<TextBlock>(window).Select(text => text.Text).ToArray();
            Check(rendered.Contains(title) && rendered.Contains(activity) && rendered.Contains("Мой этап"), "Source task text was changed in the English expanded view.");
            Click((Button)window.FindName("MinimizeButton"));
            var dots = (StackPanel)window.FindName("CompactDotsPanel");
            Button claudeDot = (Button)dots.Children[1];
            Check(System.Windows.Automation.AutomationProperties.GetName(claudeDot) == "Show task: " + title, "Accessible task name was changed.");
            Click(claudeDot);
            window.UpdateLayout();
            rendered = Visible<TextBlock>(window).Select(text => text.Text).ToArray();
            Check(rendered.Contains(title) && rendered.Contains(activity), "Source task text was changed in the English compact view.");
        }
        finally { window.Close(); }
    }

    private static void CaptureTabStates(string directory)
    {
        foreach (string language in new[] { "ru", "en" })
        foreach (string theme in new[] { "light", "dark" })
        {
            var (window, controller) = Open("active", language, theme);
            try
            {
                window.Width = 616; window.Height = 756;
                window.UpdateLayout();
                var host = (Grid)window.FindName("ProviderTabsHost");
                var tabs = (StackPanel)window.FindName("ProviderTabsPanel");
                Check(tabs.Children.Count == 3, "Expected three tabs for the two-provider case.");
                Check(tabs.Children.OfType<Button>().Select(button => button.Width).Distinct().Count() == 1,
                    "The two-provider tabs are not equally wide.");
                Check(Math.Abs(host.ActualHeight - 42) < 1e-8, "Unexpected tab track height.");
                SaveCapture(window, Path.Combine(directory, $"{theme}-{language}-all.png"));
                Click(tabs.Children.OfType<Button>().Single(button => (string)button.Tag == "claude"));
                window.UpdateLayout();
                Check(controller.SelectedProvider == "claude", "Claude filter was not selected.");
                SaveCapture(window, Path.Combine(directory, $"{theme}-{language}-claude.png"));
                var definitions = new (string Id, string Name)[] { ("codex", "Codex"), ("claude", "Claude Code"),
                    ("kimi", "Kimi Code"), ("deepseek", "DeepSeek Harness"), ("hermes", "Hermes Agent"), ("opencode", "OpenCode") };
                SampleTask template = controller.CurrentTasks[0];
                var synthetic = definitions.Select(provider => template with
                {
                    Id = "test-" + provider.Id, Provider = provider.Id, ProviderName = provider.Name,
                    Title = provider.Name + " task"
                }).ToList();
                Type controllerType = typeof(PrototypeWindow);
                controllerType.GetField("samples", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(controller, synthetic);
                controllerType.GetField("selectedProvider", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(controller, "all");
                controllerType.GetMethod("Render", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(controller, null);
                window.UpdateLayout();
                var scroll = (ScrollViewer)window.FindName("ProviderTabsScroll");
                Check(tabs.Children.Count == 7 && scroll.ScrollableWidth > 0, "Six providers did not produce scrollable tabs.");
                SaveCapture(window, Path.Combine(directory, $"{theme}-{language}-six-start.png"));
                scroll.ScrollToEnd();
                window.UpdateLayout();
                Click(tabs.Children.OfType<Button>().Single(button => (string)button.Tag == "opencode"));
                window.Dispatcher.Invoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle, new Action(() => { }));
                window.UpdateLayout();
                Check(controller.SelectedProvider == "opencode", "Scrolling changed the selected provider.");
                Check(scroll.HorizontalOffset > 0, "Scrolling to the final provider did not persist.");
                SaveCapture(window, Path.Combine(directory, $"{theme}-{language}-six-end.png"));
            }
            finally { window.Close(); }
        }
    }

    private static void SaveCapture(Window window, string path)
    {
        window.Dispatcher.Invoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle, new Action(() => { }));
        window.UpdateLayout();
        var image = new System.Windows.Media.Imaging.RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth),
            (int)Math.Ceiling(window.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        image.Render(window);
        var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
        encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(image));
        using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        encoder.Save(output);
    }

    private static (Window Window, PrototypeWindow Controller) Open(string scene, string language, string theme)
    {
        Assembly assembly = typeof(PrototypeWindow).Assembly;
        using Stream layout = assembly.GetManifestResourceStream("AITaskMonitor.Prototype.PublishedWindow.xaml")
            ?? throw new InvalidOperationException("Published WPF layout is missing.");
        var window = (Window)XamlReader.Load(layout);
        var options = new Options(theme, language, scene, false, true, null, null, false);
        var controller = new PrototypeWindow(window, options);
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = -10000; window.Top = -10000; window.ShowActivated = false; window.ShowInTaskbar = false;
        window.Show(); window.UpdateLayout();
        return (window, controller);
    }

    private static IEnumerable<T> Visible<T>(DependencyObject root) where T : FrameworkElement
    {
        if (root is FrameworkElement element && !element.IsVisible) yield break;
        if (root is T match) yield return match;
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            foreach (T child in Visible<T>(VisualTreeHelper.GetChild(root, i))) yield return child;
    }

    private static void Click(Button button) => button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static void Check(bool condition, string message)
    {
        checks++;
        if (!condition) throw new InvalidOperationException(message);
    }
}
