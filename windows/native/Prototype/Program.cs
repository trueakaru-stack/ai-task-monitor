using System.IO;
using System.Reflection;
using System.Text;
using System.Windows;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace AITaskMonitor.Prototype;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (!Options.TryParse(args, out Options? options)) return 2;

        var application = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
        using Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(
            "AITaskMonitor.Prototype.PublishedWindow.xaml")
            ?? throw new InvalidOperationException("Published WPF layout is missing.");
        var window = (Window)XamlReader.Load(resource);
        var controller = new PrototypeWindow(window, options!);
        if (options!.Offscreen)
        {
            window.WindowStartupLocation = WindowStartupLocation.Manual;
            window.Left = -10000;
            window.Top = -10000;
            window.ShowActivated = false;
            window.ShowInTaskbar = false;
        }
        application.MainWindow = window;
        int exitCode = 0;
        window.ContentRendered += (_, _) => window.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, () =>
        {
            try
            {
                if (options!.Snapshot is not null) Capture(window, options.Snapshot);
                if (options.ReadyFile is not null) WriteReadyFile(options.ReadyFile);
                if (options.ExitAfterSnapshot) window.Close();
            }
            catch (IOException) { exitCode = 3; window.Close(); }
            catch (UnauthorizedAccessException) { exitCode = 3; window.Close(); }
        });
        application.Run(window);
        GC.KeepAlive(controller);
        return exitCode;
    }

    private static void Capture(Window window, string path)
    {
        window.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth),
            (int)Math.Ceiling(window.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(window);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using FileStream stream = new(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        encoder.Save(stream);
    }

    private static void WriteReadyFile(string path)
    {
        using FileStream stream = new(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        using var writer = new StreamWriter(stream, new UTF8Encoding(false));
        writer.Write("ready\n");
    }
}

internal sealed record Options(string Theme, string Language, string Scene, bool Compact, bool Offscreen,
    string? Snapshot, string? ReadyFile, bool ExitAfterSnapshot)
{
    public static bool TryParse(string[] args, out Options? options)
    {
        string theme = "dark", language = "ru", scene = "active";
        string? snapshot = null, ready = null;
        bool compact = false, offscreen = false, exit = false;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--theme" when i + 1 < args.Length: theme = args[++i]; break;
                case "--language" when i + 1 < args.Length: language = args[++i]; break;
                case "--scene" when i + 1 < args.Length: scene = args[++i]; break;
                case "--snapshot" when i + 1 < args.Length: snapshot = args[++i]; break;
                case "--ready-file" when i + 1 < args.Length: ready = args[++i]; break;
                case "--compact": compact = true; break;
                case "--offscreen": offscreen = true; break;
                case "--exit-after-snapshot": exit = true; break;
                default: options = null; return false;
            }
        }
        if (theme is not ("dark" or "light") || language is not ("ru" or "en") ||
            (scene is not ("empty" or "active" or "claude-synthetic") && !SyntheticProviderScenarios.Names.Contains(scene, StringComparer.Ordinal)) || (exit && snapshot is null) ||
            (snapshot is not null && !Path.IsPathFullyQualified(snapshot)) ||
            (ready is not null && !Path.IsPathFullyQualified(ready)))
        {
            options = null;
            return false;
        }
        options = new(theme, language, scene, compact, offscreen, snapshot, ready, exit);
        return true;
    }
}
