using System.IO;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using AITaskMonitor.Prototype;
using AITaskMonitor.Prototype.Settings;
using AITaskMonitor.NativeUpdateController;

internal static class Program
{
    private static int checks;
    private static void Check(bool condition, string message)
    {
        checks++;
        if (!condition) throw new InvalidOperationException(message);
    }
    private static T Find<T>(Window window, string name) where T : class =>
        window.FindName(name) as T ?? throw new InvalidOperationException("Missing control: " + name);
    private static void Click(Window window, string name) =>
        Find<Button>(window, name).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static bool Visible(DependencyObject value) => ((UIElement)value).Visibility == Visibility.Visible;
    private static void Capture(Window window, string root, string name)
    {
        window.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth),
            (int)Math.Ceiling(window.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(window);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var output = new FileStream(Path.Combine(root, name + ".png"), FileMode.CreateNew, FileAccess.Write, FileShare.None);
        encoder.Save(output);
    }
    private static void CaptureSettingsEnd(Window window, string root, string stem)
    {
        ScrollViewer scroll = Find<ScrollViewer>(window, "SettingsScroll");
        scroll.ScrollToEnd();
        window.Dispatcher.Invoke(DispatcherPriority.ApplicationIdle, new Action(() => { }));
        window.UpdateLayout();
        RichTextBox box = Find<RichTextBox>(window, "FeedbackEmailBox");
        var link = Find<System.Windows.Documents.Hyperlink>(window, "FeedbackEmailLink");
        Rect first = link.ContentStart.GetCharacterRect(System.Windows.Documents.LogicalDirection.Forward);
        Rect last = link.ContentEnd.GetCharacterRect(System.Windows.Documents.LogicalDirection.Backward);
        Check(box.ActualWidth >= 100 && Math.Abs(first.Top - last.Top) <= 1 && box.ActualHeight <= 28,
            "The feedback address wrapped or expanded the settings scroller.");
        Console.WriteLine($"Feedback layout {stem}: width={box.ActualWidth:F2}, height={box.ActualHeight:F2}, extent={scroll.ExtentHeight:F2}, viewport={scroll.ViewportHeight:F2}, offset={scroll.VerticalOffset:F2}");
        Capture(window, root, "end-" + stem);
        scroll.ScrollToVerticalOffset(0);
        window.Dispatcher.Invoke(DispatcherPriority.ApplicationIdle, new Action(() => { }));
        window.UpdateLayout();
    }

    private static (Window Window, PrototypeWindow Controller) Open(PreferenceFiles files, Func<bool?>? systemTheme = null,
        Action<string>? copyFeedbackAddress = null, Action<string>? openFeedbackDraft = null)
    {
        using Stream layout = typeof(PrototypeWindow).Assembly.GetManifestResourceStream(
            "AITaskMonitor.Prototype.PublishedWindow.xaml") ?? throw new InvalidOperationException("Layout missing.");
        var window = (Window)XamlReader.Load(layout);
        var controller = new PrototypeWindow(window, new Options("dark", "ru", "active", false, true, null, null, false),
            files.Service, systemTheme ?? (() => false), () => "ru-RU", copyFeedbackAddress, openFeedbackDraft);
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = -10000;
        window.Top = -10000;
        window.ShowActivated = false;
        window.ShowInTaskbar = false;
        window.Show();
        window.UpdateLayout();
        return (window, controller);
    }
    private static JsonDocument ReadTarget(string path) => JsonDocument.Parse(File.ReadAllBytes(path));

    [STAThread]
    private static int Main(string[] args)
    {
        Check(OperatingSystem.IsWindows() && Environment.GetEnvironmentVariable("CI") == "true" &&
            Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true" &&
            Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") == "github-hosted" &&
            Environment.GetEnvironmentVariable("RUNNER_OS") == "Windows" &&
            Environment.GetEnvironmentVariable("DOTNET_ADD_GLOBAL_TOOLS_TO_PATH") == "0" &&
            Environment.GetEnvironmentVariable("HOME") is null && Environment.GetEnvironmentVariable("CODEX_HOME") is null,
            "A disposable hosted Windows environment without HOME overrides is required.");
        Check(args.Length == 1 && Path.IsPathFullyQualified(args[0]), "An absolute synthetic root is required.");
        string root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(args[0]));
        string temp = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? ""));
        Check(string.Equals(Directory.GetParent(root)?.FullName, temp, StringComparison.OrdinalIgnoreCase) &&
            Regex.IsMatch(Path.GetFileName(root), "^aitm-display-[0-9a-f]{32}$") && Directory.Exists(root),
            "The test root must be a unique hosted runner temporary directory.");
        for (DirectoryInfo? directory = new(root); directory is not null; directory = directory.Parent)
            Check((directory.Attributes & FileAttributes.ReparsePoint) == 0, "Redirected paths are rejected.");
        string work = Path.Combine(root, "fixtures", "window");
        Directory.CreateDirectory(work);
        string old = Path.Combine(work, "old.json"), target = Path.Combine(work, "native.json");
        byte[] original = Encoding.UTF8.GetBytes("{\"Theme\":\"DARK\",\"language\":\"RU\",\"unrelated\":{\"keep\":true}}");
        File.WriteAllBytes(old, original);
        var files = new PreferenceFiles(old, target);
        var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        bool systemLight = false, failCopy = false, failMail = false;
        string copied = "", opened = "";
        var first = Open(files, () => systemLight,
            address => { if (failCopy) throw new InvalidOperationException(); copied = address; },
            uri => { if (failMail) throw new InvalidOperationException(); opened = uri; });
        Window window = first.Window;
        Check(Find<Button>(window, "SettingsFooterButton").IsEnabled, "The injected settings button is not available.");
        Click(window, "SettingsFooterButton");
        Check(Visible(Find<Grid>(window, "SettingsView")) && !Visible(Find<Grid>(window, "ExpandedView")), "Settings did not open.");
        Check(Find<TextBlock>(window, "SettingsHeading").Text == "Настройки", "The old Russian language was not applied.");
        Check(Find<TextBlock>(window, "CodexCloudSourceStatus").Text == "Нет данных" &&
            (string)Find<Button>(window, "CodexCloudSourceAction").Content == "Подключить" &&
            !Find<Button>(window, "CodexCloudSourceAction").IsEnabled,
            "The unconnected cloud control had no truthful disabled state.");
        first.Controller.ApplyClaudeRegistration(ClaudeRegistration.Registered);
        Check(Find<TextBlock>(window, "ClaudeSourceStatus").Text == "Статус не подтверждён" &&
            !Find<Button>(window, "ClaudeSourceAction").IsEnabled &&
            !Find<Button>(window, "AboutSettingsButton").IsEnabled,
            "Claude registration or unfinished actions were presented incorrectly.");
        var feedbackLink = Find<System.Windows.Documents.Hyperlink>(window, "FeedbackEmailLink");
        var feedbackCopy = Find<Button>(window, "FeedbackCopyButton");
        var feedbackError = Find<TextBlock>(window, "FeedbackError");
        Check(feedbackLink.IsEnabled && feedbackCopy.IsEnabled && feedbackCopy.IsTabStop &&
            System.Windows.Automation.AutomationProperties.GetName(feedbackCopy) == "Скопировать адрес",
            "The feedback controls are not enabled and accessible.");
        Check(copied.Length == 0 && opened.Length == 0, "Feedback actions ran without user activation.");
        Click(window, "FeedbackCopyButton");
        Check(copied == "truea.k.a.ru@gmail.com" && !Visible(feedbackError),
            "Feedback copying did not request the expected address.");
        feedbackLink.RaiseEvent(new RoutedEventArgs(System.Windows.Documents.Hyperlink.ClickEvent));
        Check(opened == "mailto:truea.k.a.ru@gmail.com?subject=" +
            Uri.EscapeDataString("Отзыв или предложение об AI Task Monitor") && !Visible(feedbackError),
            "Feedback mail did not request the expected empty draft.");
        failCopy = true;
        Click(window, "FeedbackCopyButton");
        Check(Visible(feedbackError) && feedbackError.Text ==
            "Не удалось скопировать адрес. Выделите его и скопируйте вручную.",
            "A clipboard failure was not shown in Russian.");
        CaptureSettingsEnd(window, root, "error-copy-dark-ru");
        failCopy = false;
        Click(window, "FeedbackCopyButton");
        Check(!Visible(feedbackError), "A successful copy did not clear the error.");
        failMail = true;
        feedbackLink.RaiseEvent(new RoutedEventArgs(System.Windows.Documents.Hyperlink.ClickEvent));
        Check(Visible(feedbackError) && feedbackError.Text ==
            "Не удалось открыть почтовое приложение. Напишите на truea.k.a.ru@gmail.com.",
            "A mail failure was not shown in Russian.");
        CaptureSettingsEnd(window, root, "error-mail-dark-ru");
        failMail = false;
        feedbackLink.RaiseEvent(new RoutedEventArgs(System.Windows.Documents.Hyperlink.ClickEvent));
        Check(!Visible(feedbackError), "A successful mail action did not clear the error.");
        Capture(window, root, "settings-dark-ru");
        CaptureSettingsEnd(window, root, "dark-ru");

        Click(window, "LightThemeButton");
        using (JsonDocument saved = ReadTarget(target))
            Check(saved.RootElement.EnumerateObject().Count() == 1 && saved.RootElement.GetProperty("theme").GetString() == "light",
                "A theme click did not persist only the selected value.");
        Check(File.ReadAllBytes(old).AsSpan().SequenceEqual(original) &&
            ((SolidColorBrush)window.Resources["Surface"]).Color == (Color)ColorConverter.ConvertFromString("#F6F6F6"),
            "Theme selection changed legacy settings or the window did not update.");
        failCopy = true;
        Click(window, "FeedbackCopyButton");
        Check(Visible(feedbackError) && feedbackError.Text.StartsWith("Не удалось скопировать", StringComparison.Ordinal),
            "A clipboard error is missing in the light Russian theme.");
        CaptureSettingsEnd(window, root, "error-copy-light-ru");
        failCopy = false;
        Click(window, "FeedbackCopyButton");
        failMail = true;
        feedbackLink.RaiseEvent(new RoutedEventArgs(System.Windows.Documents.Hyperlink.ClickEvent));
        Check(Visible(feedbackError) && feedbackError.Text.StartsWith("Не удалось открыть", StringComparison.Ordinal),
            "A mail error is missing in the light Russian theme.");
        CaptureSettingsEnd(window, root, "error-mail-light-ru");
        failMail = false;
        feedbackLink.RaiseEvent(new RoutedEventArgs(System.Windows.Documents.Hyperlink.ClickEvent));
        Capture(window, root, "settings-light-ru");
        CaptureSettingsEnd(window, root, "light-ru");
        var sourceTask = new AITaskMonitor.Claude.Task
        {
            Id = "custom", Activity = "Пользовательский текст", Updated = DateTime.UtcNow, Started = DateTime.UtcNow,
            StartKey = "test", Unconfirmed = false, PlanConfirmed = true,
            Steps = [new AITaskMonitor.Claude.Step { id = "1", title = "Название от источника", status = "active", generated = false }]
        };
        first.Controller.ApplyClaudeSource(new AITaskMonitor.Claude.ClaudeSourceSnapshot([sourceTask], false));
        Click(window, "EnglishLanguageButton");
        using (JsonDocument saved = ReadTarget(target))
            Check(saved.RootElement.EnumerateObject().Count() == 2 && saved.RootElement.GetProperty("theme").GetString() == "light" &&
                saved.RootElement.GetProperty("language").GetString() == "en", "Language selection did not preserve the theme.");
        Check(Find<TextBlock>(window, "SettingsHeading").Text == "Settings" &&
            (string)Find<Button>(window, "SystemThemeButton").Content == "System" &&
            (string)Find<Button>(window, "RussianLanguageButton").Content == "Русский", "The settings labels were not translated correctly.");
        Check(Find<TextBlock>(window, "ClaudeSourceStatus").Text == "Status unconfirmed" &&
            !Find<Button>(window, "ClaudeSourceAction").IsEnabled,
            "The Claude registration status did not follow the selected language.");
        Check(Find<TextBlock>(window, "CodexCloudSourceStatus").Text == "No data" &&
            (string)Find<Button>(window, "CodexCloudSourceAction").Content == "Connect" &&
            !Find<Button>(window, "CodexCloudSourceAction").IsEnabled, "The cloud fallback was not translated or was enabled.");
        SampleTask retained = first.Controller.CurrentTasks.Single(task => task.Id == "claude:custom");
        Check(retained.Activity == "Пользовательский текст" && retained.Steps.Single().Title == "Название от источника" &&
            retained.Title == "Claude Code task", "Changing language altered source text or failed to relocalize a generated title.");
        Check(System.Windows.Automation.AutomationProperties.GetName(feedbackCopy) == "Copy email address",
            "The feedback copy control was not translated.");
        failCopy = true;
        Click(window, "FeedbackCopyButton");
        Check(Visible(feedbackError) && feedbackError.Text ==
            "Could not copy the address. Select and copy it manually.",
            "A clipboard failure was not shown in English.");
        CaptureSettingsEnd(window, root, "error-copy-light-en");
        Click(window, "RussianLanguageButton");
        Check(feedbackError.Text == "Не удалось скопировать адрес. Выделите его и скопируйте вручную.",
            "A visible feedback error did not switch to Russian.");
        Click(window, "EnglishLanguageButton");
        Check(feedbackError.Text == "Could not copy the address. Select and copy it manually.",
            "A visible feedback error did not switch to English.");
        failCopy = false;
        Click(window, "FeedbackCopyButton");
        failMail = true;
        feedbackLink.RaiseEvent(new RoutedEventArgs(System.Windows.Documents.Hyperlink.ClickEvent));
        Check(Visible(feedbackError) && feedbackError.Text ==
            "Could not open your email app. Write to truea.k.a.ru@gmail.com.",
            "A mail failure was not shown in English.");
        CaptureSettingsEnd(window, root, "error-mail-light-en");
        failMail = false;
        feedbackLink.RaiseEvent(new RoutedEventArgs(System.Windows.Documents.Hyperlink.ClickEvent));
        Check(opened == "mailto:truea.k.a.ru@gmail.com?subject=" +
            Uri.EscapeDataString("AI Task Monitor feedback or suggestion") && !Visible(feedbackError),
            "The English feedback mail draft or recovery is incorrect.");
        Capture(window, root, "settings-light-en");
        CaptureSettingsEnd(window, root, "light-en");
        Click(window, "DarkThemeButton");
        failCopy = true;
        Click(window, "FeedbackCopyButton");
        Check(Visible(feedbackError) && feedbackError.Text.StartsWith("Could not copy", StringComparison.Ordinal),
            "A clipboard error is missing in the dark English theme.");
        CaptureSettingsEnd(window, root, "error-copy-dark-en");
        failCopy = false;
        Click(window, "FeedbackCopyButton");
        failMail = true;
        feedbackLink.RaiseEvent(new RoutedEventArgs(System.Windows.Documents.Hyperlink.ClickEvent));
        Check(Visible(feedbackError) && feedbackError.Text.StartsWith("Could not open", StringComparison.Ordinal),
            "A mail error is missing in the dark English theme.");
        CaptureSettingsEnd(window, root, "error-mail-dark-en");
        failMail = false;
        feedbackLink.RaiseEvent(new RoutedEventArgs(System.Windows.Documents.Hyperlink.ClickEvent));
        Capture(window, root, "settings-dark-en");
        CaptureSettingsEnd(window, root, "dark-en");
        Click(window, "SystemThemeButton");
        Click(window, "SystemLanguageButton");
        using (JsonDocument saved = ReadTarget(target))
            Check(saved.RootElement.GetProperty("theme").GetString() == "system" &&
                saved.RootElement.GetProperty("language").GetString() == "system" &&
                Find<TextBlock>(window, "SettingsHeading").Text == "Настройки" &&
                ((SolidColorBrush)window.Resources["Surface"]).Color == (Color)ColorConverter.ConvertFromString("#202020"),
                "The selected system modes did not use the supplied system preferences.");
        systemLight = true;
        var frame = new DispatcherFrame();
        var stop = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(2300) };
        stop.Tick += (_, _) => { stop.Stop(); frame.Continue = false; };
        stop.Start();
        Dispatcher.PushFrame(frame);
        Check(((SolidColorBrush)window.Resources["Surface"]).Color == (Color)ColorConverter.ConvertFromString("#F6F6F6"),
            "A later system-theme change was not applied.");
        Click(window, "EnglishLanguageButton");
        Click(window, "DarkThemeButton");
        first.Controller.ApplySyntheticUpdate(new UpdateInfo("0.2.7-alpha", "https://example.invalid/update"),
            () => throw new InvalidOperationException("Synthetic download error"));
        Click(window, "UpdateDownloadButton");
        IInputElement? focusBeforeLanguage = Keyboard.FocusedElement;
        Click(window, "RussianLanguageButton");
        Check(Find<TextBlock>(window, "UpdateVersionText").Text == "Версия 0.2.7-alpha доступна для скачивания" &&
            Visible(Find<Grid>(window, "UpdateOverlay")) && Visible(Find<TextBlock>(window, "UpdateOpenError")) &&
            Find<TextBlock>(window, "UpdateOpenError").Text == "Не удалось открыть страницу загрузки." &&
            ReferenceEquals(Keyboard.FocusedElement, focusBeforeLanguage), "Changing language reset the open update dialog or its state.");
        retained = first.Controller.CurrentTasks.Single(task => task.Id == "claude:custom");
        Check(retained.Title == "Задача Claude Code" && retained.Activity == "Пользовательский текст" &&
            retained.Steps.Single().Title == "Название от источника", "Switching back changed Claude data or left its generated title untranslated.");
        Click(window, "EnglishLanguageButton");
        Check(Find<TextBlock>(window, "UpdateVersionText").Text == "Version 0.2.7-alpha is available to download" &&
            Visible(Find<TextBlock>(window, "UpdateOpenError")) &&
            Find<TextBlock>(window, "UpdateOpenError").Text == "Could not open the download page.", "The update dialog did not switch back to English.");
        Click(window, "UpdateLaterButton");
        Click(window, "SettingsBackButton");
        Check(Visible(Find<Grid>(window, "ExpandedView")) && !Visible(Find<Grid>(window, "SettingsView")), "The back button did not return to tasks.");
        Check(Find<TextBlock>(window, "ProgressHeading").Text == "Progress", "The main screen did not switch language.");
        window.Close();

        var second = Open(new PreferenceFiles(old, target));
        Click(second.Window, "SettingsFooterButton");
        Check(Find<TextBlock>(second.Window, "SettingsHeading").Text == "Settings" &&
            ((SolidColorBrush)second.Window.Resources["Surface"]).Color == (Color)ColorConverter.ConvertFromString("#202020"),
            "Selections did not survive a new window.");
        Click(second.Window, "RussianLanguageButton");
        Check(Find<TextBlock>(second.Window, "SettingsHeading").Text == "Настройки", "Switching back to Russian failed.");
        Check(File.ReadAllBytes(old).AsSpan().SequenceEqual(original), "Changing language touched the old file.");
        byte[] beforeLock = File.ReadAllBytes(target);
        using (var held = new FileStream(target + ".lock", FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            Click(second.Window, "LightThemeButton");
            Check(Visible(Find<TextBlock>(second.Window, "LanguageSettingsError")) &&
                ((SolidColorBrush)second.Window.Resources["Surface"]).Color == (Color)ColorConverter.ConvertFromString("#202020") &&
                File.ReadAllBytes(target).AsSpan().SequenceEqual(beforeLock), "A failed save changed the theme or target.");
        }
        Click(second.Window, "LightThemeButton");
        Check(!Visible(Find<TextBlock>(second.Window, "LanguageSettingsError")), "A successful retry did not clear the save error.");
        second.Window.Close();

        string invalidOld = Path.Combine(work, "invalid.json"), partial = Path.Combine(work, "partial.json");
        byte[] invalid = Encoding.UTF8.GetBytes("{broken");
        File.WriteAllBytes(invalidOld, invalid);
        File.WriteAllText(partial, "{\"theme\":\"dark\",\"foreign\":7}", new UTF8Encoding(false));
        var invalidWindow = Open(new PreferenceFiles(invalidOld, partial));
        Click(invalidWindow.Window, "SettingsFooterButton");
        Check(Visible(Find<TextBlock>(invalidWindow.Window, "LanguageSettingsError")), "An unreadable missing setting was hidden.");
        Click(invalidWindow.Window, "LightThemeButton");
        using (JsonDocument saved = ReadTarget(partial))
            Check(saved.RootElement.GetProperty("theme").GetString() == "light" && saved.RootElement.GetProperty("foreign").GetInt32() == 7 &&
                !saved.RootElement.TryGetProperty("language", out _), "One choice guessed or overwrote a missing value.");
        Check(Visible(Find<TextBlock>(invalidWindow.Window, "LanguageSettingsError")) &&
            File.ReadAllBytes(invalidOld).AsSpan().SequenceEqual(invalid), "The invalid old file was hidden or changed.");
        Click(invalidWindow.Window, "EnglishLanguageButton");
        Check(!Visible(Find<TextBlock>(invalidWindow.Window, "LanguageSettingsError")) &&
            Find<TextBlock>(invalidWindow.Window, "SettingsHeading").Text == "Settings", "Two explicit choices did not resolve the unreadable fallback.");
        invalidWindow.Window.Close();
        application.Shutdown();
        Console.WriteLine($"Display host: {checks} synthetic checks passed.");
        return 0;
    }
}
