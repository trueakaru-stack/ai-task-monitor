using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace AITaskMonitor.CodexCloud
{
    // Runs only the official CLI command. It never reads credentials or logs output.
    public sealed class Command : IDisposable
    {
        private readonly object gate = new object();
        private readonly Task<Result> work;
        private Process process;
        private bool cancelled;

        public sealed class Result
        {
            public bool Ok { get; internal set; }
            public string Json { get; internal set; }
        }

        public Command(string executable, string cursor, int timeoutMilliseconds)
        {
            if (String.IsNullOrEmpty(executable) || timeoutMilliseconds < 1 || timeoutMilliseconds > 120000)
                throw new ArgumentException("Invalid command configuration.");
            work = Task.Run(() => Execute(executable, cursor, timeoutMilliseconds));
        }

        public bool Completed { get { return work.IsCompleted; } }

        public Result GetResult()
        {
            if (!work.IsCompleted) return null;
            try { return work.GetAwaiter().GetResult(); }
            catch { return new Result { Ok = false, Json = null }; }
        }

        public void Cancel()
        {
            lock (gate)
            {
                cancelled = true;
                Stop(process);
            }
        }

        public void Dispose() { Cancel(); }

        private Result Execute(string executable, string cursor, int timeoutMilliseconds)
        {
            Process child = null;
            try
            {
                string arguments = "cloud list --json --limit 20";
                if (!String.IsNullOrEmpty(cursor)) arguments += " --cursor " + QuoteArgument(cursor);
                var start = new ProcessStartInfo(executable, arguments) {
                    UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden,
                    RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true
                };
                child = new Process { StartInfo = start };
                lock (gate)
                {
                    if (cancelled) return new Result { Ok = false };
                    if (!child.Start()) return new Result { Ok = false };
                    process = child;
                }
                child.StandardInput.Close();
                Task<byte[]> output = ReadBounded(child.StandardOutput.BaseStream, child, 1048576, true);
                Task<byte[]> errors = ReadBounded(child.StandardError.BaseStream, child, 65536, false);
                if (!child.WaitForExit(timeoutMilliseconds)) { Stop(child); return new Result { Ok = false }; }
                if (!Task.WaitAll(new Task[] { output, errors }, 2000)) { Stop(child); return new Result { Ok = false }; }
                lock (gate) { if (cancelled) return new Result { Ok = false }; }
                if (child.ExitCode != 0) return new Result { Ok = false };
                return new Result { Ok = true, Json = new UTF8Encoding(false, true).GetString(output.Result) };
            }
            catch { Stop(child); return new Result { Ok = false }; }
            finally
            {
                lock (gate) { process = null; }
                if (child != null) child.Dispose();
            }
        }

        private static async Task<byte[]> ReadBounded(Stream stream, Process child, int maximum, bool keep)
        {
            using (var buffer = new MemoryStream())
            {
                var bytes = new byte[8192];
                int total = 0;
                while (true)
                {
                    int count = await stream.ReadAsync(bytes, 0, bytes.Length).ConfigureAwait(false);
                    if (count == 0) break;
                    total += count;
                    if (total > maximum) { Stop(child); throw new InvalidDataException(); }
                    if (keep) buffer.Write(bytes, 0, count);
                }
                return buffer.ToArray();
            }
        }

        private static void Stop(Process child)
        {
            try { if (child != null && !child.HasExited) child.Kill(); }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
        }

        private static string QuoteArgument(string value)
        {
            var result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { result.Append('\\', slashes * 2 + 1); result.Append('"'); }
                else { result.Append('\\', slashes); result.Append(c); }
                slashes = 0;
            }
            result.Append('\\', slashes * 2);
            return result.Append('"').ToString();
        }
    }
}
