using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace AITaskMonitor.Hermes
{
    // A bounded process for our isolated preparation bridge.
    // The request travels through stdin; neither paths nor profile names are logged.
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

        public Command(string python, string script, string directory, string json, int timeoutMilliseconds)
        {
            if (String.IsNullOrEmpty(python) || String.IsNullOrEmpty(script) || String.IsNullOrEmpty(directory) ||
                String.IsNullOrEmpty(json) || Encoding.UTF8.GetByteCount(json) > 8192 ||
                timeoutMilliseconds < 1 || timeoutMilliseconds > 120000)
                throw new ArgumentException("Invalid bridge configuration.");
            work = Task.Run(() => Execute(python, script, directory, json, timeoutMilliseconds));
        }

        public bool Completed { get { return work.IsCompleted; } }

        public Result GetResult()
        {
            if (!work.IsCompleted) return null;
            try { return work.GetAwaiter().GetResult(); }
            catch { return new Result { Ok = false }; }
        }

        public void Cancel()
        {
            lock (gate) { cancelled = true; Stop(process); }
        }

        public void Dispose() { Cancel(); }

        private Result Execute(string python, string script, string directory, string json, int timeout)
        {
            Process child = null;
            try
            {
                var start = new ProcessStartInfo(python, "-I -S -B " + QuoteArgument(script)) {
                    WorkingDirectory = directory, UseShellExecute = false, CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden, RedirectStandardInput = true,
                    RedirectStandardOutput = true, RedirectStandardError = true
                };
                // Ignore user startup hooks and do not pass agent credentials to the bridge.
                start.EnvironmentVariables.Clear();
                foreach (string name in new[] { "SYSTEMROOT", "WINDIR" })
                {
                    string value = Environment.GetEnvironmentVariable(name);
                    if (!String.IsNullOrEmpty(value)) start.EnvironmentVariables[name] = value;
                }
                child = new Process { StartInfo = start };
                lock (gate)
                {
                    if (cancelled) return new Result { Ok = false };
                    if (!child.Start()) return new Result { Ok = false };
                    process = child;
                }
                Task<byte[]> output = ReadBounded(child.StandardOutput.BaseStream, child, 131072);
                Task<byte[]> errors = ReadBounded(child.StandardError.BaseStream, child, 16384);
                byte[] body = Encoding.UTF8.GetBytes(json);
                Task input = Task.Run(() => {
                    child.StandardInput.BaseStream.Write(body, 0, body.Length);
                    child.StandardInput.Close();
                });
                if (!child.WaitForExit(timeout)) { Stop(child); return new Result { Ok = false }; }
                if (!Task.WaitAll(new Task[] { input, output, errors }, 2000)) { Stop(child); return new Result { Ok = false }; }
                lock (gate) { if (cancelled) return new Result { Ok = false }; }
                if (child.ExitCode != 0 || errors.Result.Length != 0) return new Result { Ok = false };
                return new Result { Ok = true, Json = new UTF8Encoding(false, true).GetString(output.Result) };
            }
            catch { Stop(child); return new Result { Ok = false }; }
            finally
            {
                lock (gate) { process = null; }
                if (child != null) child.Dispose();
            }
        }

        private static async Task<byte[]> ReadBounded(Stream stream, Process child, int maximum)
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
                    buffer.Write(bytes, 0, count);
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
