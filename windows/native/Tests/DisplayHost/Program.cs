using System.IO;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using AITaskMonitor.Prototype;
using AITaskMonitor.Prototype.Settings;

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
    private static (Window Window, PrototypeWindow Controller) Open(PreferenceFiles files)
    {
        using Stream layout = typeof(PrototypeWindow).Assembly.GetManifestResourceStream(
            "AITaskMonitor.Prototype.PublishedWindow.xaml") ?? throw new InvalidOperationException("Layout missing.");
        var window = (Window)XamlReader.Load(layout);
        var controller = new PrototypeWindow(window, new Options("dark", "ru", "active", false, true, null, null, false),
            files.Service, () => false, () => "ru-RU");
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
        var first = Open(files);
        Window window = first.Window;
        Check(Find<Button>(window, "SettingsFooterButton").IsEnabled, "The injected settings button is not available.");
        Click(window, "SettingsFooterButton");
        Check(Visible(Find<Grid>(window, "SettingsView")) && !Visible(Find<Grid>(window, "ExpandedView")), "Settings did not open.");
        Check(Find<TextBlock>(window, "SettingsHeading").Text == "Настройки", "The old Russian language was not applied.");
        Capture(window, root, "settings-dark-ru");

        Click(window, "LightThemeButton");
        using (JsonDocument saved = ReadTarget(target))
            Check(saved.RootElement.EnumerateObject().Count() == 1 && saved.RootElement.GetProperty("theme").GetString() == "light",
                "A theme click did not persist only the selected value.");
        Check(File.ReadAllBytes(old).AsSpan().SequenceEqual(original) &&
            ((SolidColorBrush)window.Resources["Surface"]).Color == (Color)ColorConverter.ConvertFromString("#F6F6F6"),
            "Theme selection changed legacy settings or the window did not update.");
        Capture(window, root, "settings-light-ru");
        Click(window, "EnglishLanguageButton");
        using (JsonDocument saved = ReadTarget(target))
            Check(saved.RootElement.EnumerateObject().Count() == 2 && saved.RootElement.GetProperty("theme").GetString() == "light" &&
                saved.RootElement.GetProperty("language").GetString() == "en", "Language selection did not preserve the theme.");
        Check(Find<TextBlock>(window, "SettingsHeading").Text == "Settings" &&
            (string)Find<Button>(window, "SystemThemeButton").Content == "System" &&
            (string)Find<Button>(window, "RussianLanguageButton").Content == "Русский", "The settings labels were not translated correctly.");
        Capture(window, root, "settings-light-en");
        Click(window, "DarkThemeButton");
        Capture(window, root, "settings-dark-en");
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
