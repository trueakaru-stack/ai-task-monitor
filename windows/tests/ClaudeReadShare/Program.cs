using System.Text;
using Reader = AITaskMonitor.Claude.Reader;

if (args.Length != 1) throw new ArgumentException("Synthetic input path required.");
string root = Environment.GetEnvironmentVariable("AITM_READSHARE_ROOT") ?? throw new InvalidOperationException();
string file = Path.GetFullPath(args[0]);
if (!file.StartsWith(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar,
        StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Synthetic input outside fixture.");
string text = File.ReadAllText(file, Encoding.UTF8);
var tasks = Reader.Read(text, "", DateTime.UtcNow, DateTime.UtcNow.AddMinutes(-5));
Console.WriteLine(tasks.Length + ":" + (tasks.Length == 1 && tasks[0].Unconfirmed ? "unconfirmed" : "other"));
