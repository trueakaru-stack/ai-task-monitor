import Darwin
import Foundation

private enum FixtureError: Error { case badArguments, unexpectedState, timeout, childFailure }

private func hold(_ directory: URL, ready: URL, release: URL) throws {
    guard let lease = try ReleaseScheduleFileStore(directory: directory).acquire() else { throw FixtureError.unexpectedState }
    try Data("ready".utf8).write(to: ready)
    let until = Date(timeIntervalSinceNow: 10)
    while !FileManager.default.fileExists(atPath: release.path) {
        guard Date() < until else { throw FixtureError.timeout }
        usleep(10_000)
    }
    withExtendedLifetime(lease) { }
}

private func attempt(_ directory: URL, expected: String) throws {
    let lease = try ReleaseScheduleFileStore(directory: directory).acquire()
    guard (expected == "busy" && lease == nil) || (expected == "free" && lease != nil) else {
        throw FixtureError.unexpectedState
    }
    withExtendedLifetime(lease) { }
}

private func child(_ arguments: [String]) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

private func waitUntilReady(_ process: Process, marker: URL) throws {
    let until = Date(timeIntervalSinceNow: 5)
    while !FileManager.default.fileExists(atPath: marker.path) {
        guard process.isRunning else { throw FixtureError.childFailure }
        guard Date() < until else { throw FixtureError.timeout }
        usleep(10_000)
    }
}

private func verify(_ directory: URL, expected: String) throws {
    let process = try child(["try", directory.path, expected])
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw FixtureError.childFailure }
}

private func runSyntheticProcesses() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-release-lease-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("state")

    for forceStop in [false, true] {
        let ready = root.appendingPathComponent("ready-\(forceStop)")
        let release = root.appendingPathComponent("release-\(forceStop)")
        let holder = try child(["hold", directory.path, ready.path, release.path])
        defer { if holder.isRunning { holder.terminate(); holder.waitUntilExit() } }
        try waitUntilReady(holder, marker: ready)
        try verify(directory, expected: "busy")
        if forceStop { holder.terminate() }
        else { try Data("release".utf8).write(to: release) }
        holder.waitUntilExit()
        if !forceStop && holder.terminationStatus != 0 { throw FixtureError.childFailure }
        try verify(directory, expected: "free")
    }
    print("synthetic cross-process lease and process-exit release: passed")
}

do {
    let args = CommandLine.arguments
    if args.count == 1 { try runSyntheticProcesses() }
    else if args.count == 5 && args[1] == "hold" {
        try hold(URL(fileURLWithPath: args[2]), ready: URL(fileURLWithPath: args[3]), release: URL(fileURLWithPath: args[4]))
    } else if args.count == 4 && args[1] == "try" {
        try attempt(URL(fileURLWithPath: args[2]), expected: args[3])
    } else { throw FixtureError.badArguments }
} catch {
    fputs("synthetic release lease fixture failed: \(error)\n", stderr)
    exit(1)
}
