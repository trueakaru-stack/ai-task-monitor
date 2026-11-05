using System.Text.Json;
using AITaskMonitor.NativeUpdateRetry;

if (args.Length != 1) throw new ArgumentException("Synthetic fixture path required.");
using JsonDocument document = JsonDocument.Parse(File.ReadAllBytes(args[0]));
var result = new List<long>();
foreach (JsonElement item in document.RootElement.EnumerateArray())
{
    string?[] Strings(string name) => item.GetProperty(name).EnumerateArray().Select(x => x.ValueKind == JsonValueKind.Null ? null : x.GetString()).ToArray();
    result.Add(UpdateRetryPolicy.FailureDelay(item.GetProperty("failures").GetInt32(), Strings("after"), Strings("reset"),
        Strings("dates"), DateTimeOffset.Parse(item.GetProperty("now").GetString()!)).Ticks);
}
Console.WriteLine(JsonSerializer.Serialize(result));

var schedule = new UpdateRetrySchedule();
if (!schedule.Due(0)) throw new Exception("An unscheduled check must be due immediately.");
var wall = new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
if (!schedule.Record(false, 100, 10, wall)) throw new Exception("Initial result rejected.");
if (schedule.Failures != 1 || schedule.Due(36099) || !schedule.Due(36100)) throw new Exception("One-hour deadline mismatch.");
if (schedule.Due(50) || schedule.ScheduledAt != 50 || schedule.Due(36049) || !schedule.Due(36050)) throw new Exception("Clock reset mismatch.");
if (!schedule.Record(true, 36050, 10, wall)) throw new Exception("Due result rejected.");
if (schedule.Failures != 0 || schedule.Due(900049) || !schedule.Due(900050)) throw new Exception("Success schedule mismatch.");
var guarded = new UpdateRetrySchedule();
if (!guarded.Record(false, 0, 10, wall, new string?[] { "86400" })) throw new Exception("Initial hint rejected.");
if (guarded.Record(false, 10, 10, wall) || guarded.Delay != TimeSpan.FromDays(1) || guarded.Due(72010) || !guarded.Due(864000))
    throw new Exception("Early result shortened the requested server delay.");
