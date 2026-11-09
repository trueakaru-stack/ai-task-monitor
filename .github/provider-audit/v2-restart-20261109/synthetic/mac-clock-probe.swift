// Test-only process clock comparison. It does not prove behavior after sleep,
// process identity, ordering of events, or correctness in an embedded runtime.
import Darwin
import Dispatch
import Foundation

enum ProbeError: Error { case arguments, timebase, overflow, child, output }

func continuousNanoseconds() throws -> UInt64 {
    var info = mach_timebase_info_data_t()
    guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { throw ProbeError.timebase }
    let ticks = mach_continuous_time()
    let divisor = UInt64(info.denom), multiplier = UInt64(info.numer)
    let (whole, overflow1) = (ticks / divisor).multipliedReportingOverflow(by: multiplier)
    let (part, overflow2) = (ticks % divisor).multipliedReportingOverflow(by: multiplier)
    let (value, overflow3) = whole.addingReportingOverflow(part / divisor)
    guard !overflow1 && !overflow2 && !overflow3 else { throw ProbeError.overflow }
    return value
}

// Pass absolute paths to a runtime executable and the adjacent JS file.
guard CommandLine.arguments.count == 3,
      CommandLine.arguments[1].hasPrefix("/"), CommandLine.arguments[2].hasPrefix("/") else {
    throw ProbeError.arguments
}
let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
child.arguments = [CommandLine.arguments[2]]
child.environment = [:] // Do not pass HOME, CODEX_HOME, credentials, or a user profile.
let pipe = Pipe()
child.standardOutput = pipe
child.standardError = FileHandle.nullDevice
let awakeBefore = DispatchTime.now().uptimeNanoseconds
let continuousBefore = try continuousNanoseconds()
try child.run()
let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
child.waitUntilExit()
let continuousAfter = try continuousNanoseconds()
let awakeAfter = DispatchTime.now().uptimeNanoseconds
guard child.terminationStatus == 0, bytes.count <= 4096,
      let sample = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      let beforeText = sample["before"] as? String, let childBefore = UInt64(beforeText),
      let afterText = sample["after"] as? String, let childAfter = UInt64(afterText),
      let age = sample["uptime"] as? Double, age.isFinite, age >= 0,
      let runtime = sample["runtime"] as? String, let version = sample["version"] as? String else {
    throw ProbeError.output
}
guard childBefore <= childAfter else { throw ProbeError.output }
let inContinuousWindow = continuousBefore <= childBefore && childAfter <= continuousAfter
let inAwakeWindow = awakeBefore <= childBefore && childAfter <= awakeAfter
let result: [String: Any] = ["runtime": runtime, "version": version,
    "libuv": sample["libuv"] ?? NSNull(), "uptime": age,
    "inContinuousWindow": inContinuousWindow, "inAwakeWindow": inAwakeWindow,
    "awakeBefore": String(awakeBefore), "awakeAfter": String(awakeAfter),
    "continuousBefore": String(continuousBefore), "continuousAfter": String(continuousAfter),
    "childBefore": beforeText, "childAfter": afterText]
let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
FileHandle.standardOutput.write(output + Data([0x0a]))
// Both Booleans are measurements, not universal assertions. Consumers must
// reject an unverified runtime; never promote a status from this probe alone.
