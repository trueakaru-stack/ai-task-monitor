import Foundation
import Darwin

// The worker owns the reader, its source-loss latch and phase evidence on one
// serial queue. It returns only bounded observations; phase keys stay private.
enum ClaudeSourceOutcome {
    case disconnected
    case noEvents
    case snapshot(ClaudeTaskSnapshot)
    case failed(Error)
    case changed
}

struct ClaudeSourceEvents {
    var gap = false
    var ordinary: [ClaudeLoopEvent] = []
    var affectedSessions: Set<String> = []
    var lifecycleSessions: Set<String> = []
    var affectsAll = false
}

// A snapshot is not, by itself, proof of a complete source or a confirmed
// plan. Consumers must honor connection, phase uncertainty and all four
// event batches even when the journal read fails. A batch gap resets its
// associated diagnostics before any later events are consumed.
struct ClaudeSourceRead {
    let generation: UInt64
    let connection: ClaudeIntegration.ConnectionState?
    let outcome: ClaudeSourceOutcome
    let before: ClaudeSourceEvents
    let middle: ClaudeSourceEvents
    let after: ClaudeSourceEvents
    let final: ClaudeSourceEvents
    let earlierTasks: [MonitoredTask]
    let changedSessionIDs: Set<String>
    let changesAffectAll: Bool
    let phaseUncertainSessions: Set<String>
    let phasePoisoned: Bool
    let channelUnavailable: Bool

    func invalidated() -> ClaudeSourceRead {
        ClaudeSourceRead(generation: generation, connection: nil, outcome: .changed,
                         before: ClaudeSourceEvents(gap: true, affectsAll: true),
                         middle: ClaudeSourceEvents(gap: true, affectsAll: true),
                         after: ClaudeSourceEvents(gap: true, affectsAll: true),
                         final: ClaudeSourceEvents(gap: true, affectsAll: true),
                         earlierTasks: [], changedSessionIDs: [], changesAffectAll: true,
                         phaseUncertainSessions: [], phasePoisoned: true, channelUnavailable: true)
    }
}

// Its owner must call close() when the window is released. A blocked queue
// retains the worker, so deinit alone cannot guarantee timely shutdown.
final class ClaudeSourceWorker {
    private let queue = DispatchQueue(label: "ai-task-monitor.claude-source", qos: .utility)
    private let control = NSLock()
    private var closed = false
    private var busy = false
    private var generation: UInt64 = 0
    private var activeChannel: ClaudeLoopChannel?

    // These values are accessed only on `queue`.
    private let reader: ClaudeTaskReader
    private let connection: () throws -> ClaudeIntegration.ConnectionState
    private let channelProfile: URL?
    private let requiresChannel: Bool
    private let beforeOpenChannelForTests: (() -> Void)?
    private let beforeDeliveryForTests: (() -> Void)?
    private let afterSecondReadForTests: (() -> Void)?
    private var channel: ClaudeLoopChannel?
    private var evidence = ClaudePhaseEvidence()
    private var sawEvents = false
    private var processedGeneration: UInt64 = 0
    private var pendingTransportGap = false
    private var lastObservationStartedAt: TimeInterval = 0

    init(reader: ClaudeTaskReader, channelProfile: URL?, requiresChannel: Bool,
         beforeOpenChannelForTests: (() -> Void)? = nil,
         beforeDeliveryForTests: (() -> Void)? = nil,
         afterSecondReadForTests: (() -> Void)? = nil,
         connection: @escaping () throws -> ClaudeIntegration.ConnectionState) {
        self.reader = reader
        self.channelProfile = channelProfile
        self.requiresChannel = requiresChannel
        self.beforeOpenChannelForTests = beforeOpenChannelForTests
        self.beforeDeliveryForTests = beforeDeliveryForTests
        self.afterSecondReadForTests = afterSecondReadForTests
        self.connection = connection
    }

    deinit { shutdown() }

    // The caller can coalesce refreshes without ever starting a second reader.
    @MainActor
    @discardableResult
    func tryRead(observedSince: Date, completion: @escaping @MainActor (ClaudeSourceRead) -> Void) -> Bool {
        control.lock()
        guard !closed, !busy else { control.unlock(); return false }
        busy = true
        let requested = generation
        let language = AppLanguage.current
        control.unlock()
        queue.async {
            let result = AppLanguage.withSourceLanguage(language) {
                self.read(observedSince: observedSince, generation: requested)
            }
            let observationStartedAt = self.lastObservationStartedAt
            self.beforeDeliveryForTests?()
            self.control.lock()
            self.busy = false
            let isClosed = self.closed
            let current = self.generation == requested
            self.control.unlock()
            if !current { self.invalidateEvidenceAndRequestStop() }
            guard !isClosed else { return }
            let deliver = current ? result : result.invalidated()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.control.lock()
                let alive = !self.closed
                let stillCurrent = self.generation == requested
                self.control.unlock()
                guard alive else { return }
                let timely = ProcessInfo.processInfo.systemUptime - observationStartedAt < 2
                let sameLanguage = AppLanguage.current == language
                completion(stillCurrent && timely && sameLanguage ? deliver : deliver.invalidated())
            }
        }
        return true
    }

    // Invalidates a read immediately. A stopped channel is not replaced until
    // its receiver has actually released ownership of the socket.
    @MainActor
    func invalidate() {
        control.lock()
        generation &+= 1
        let current = activeChannel
        control.unlock()
        current?.requestStop()
    }

    // Closing a window cannot wait for a stuck reader or socket cleanup.
    @MainActor
    func close() {
        shutdown()
    }

    // Only an owner's deinit may call this from outside MainActor; its weak
    // callback cannot apply a result after that owner has been released.
    func shutdownForOwnerDeinit() {
        shutdown()
    }

    private func shutdown() {
        control.lock()
        guard !closed else { control.unlock(); return }
        closed = true
        generation &+= 1
        let current = activeChannel
        control.unlock()
        current?.requestStop()
    }

    private func isCurrent(_ requested: UInt64) -> Bool {
        control.lock(); defer { control.unlock() }
        return !closed && generation == requested
    }

    private func journalExists() throws -> Bool {
        var info = stat()
        if reader.eventFile.path.withCString({ lstat($0, &info) }) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw ClaudeReadError.incomplete }
            return true
        }
        let reason = errno
        if reason == ENOENT { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(reason))
    }

    // XCTest uses the real receiver to verify that queued frames are not
    // lost across journal errors or concurrent snapshot reads.
    var channelForTesting: ClaudeLoopChannel? {
        control.lock(); defer { control.unlock() }
        return activeChannel
    }

    #if DEBUG
    func hasPendingOrdinaryForTesting(_ session: String) -> Bool {
        control.lock(); let current = activeChannel; control.unlock()
        return current?.hasPendingOrdinaryForTesting(session) ?? false
    }

    var channelStoppedForTesting: Bool {
        control.lock(); let current = activeChannel; control.unlock()
        return current?.isStopped ?? true
    }
    #endif

    private func invalidateEvidenceAndRequestStop() {
        guard let channel else { return }
        evidence.invalidate()
        pendingTransportGap = true
        channel.requestStop()
    }

    private func install(_ newChannel: ClaudeLoopChannel, generation requested: UInt64) -> Bool {
        control.lock()
        let valid = !closed && generation == requested
        if valid { activeChannel = newChannel }
        control.unlock()
        if !valid { newChannel.requestStop() }
        return valid
    }

    private func clearStoppedChannel() {
        guard let old = channel, old.isStopped else { return }
        evidence.invalidate()
        pendingTransportGap = true
        channel = nil
        control.lock()
        if activeChannel === old { activeChannel = nil }
        control.unlock()
    }

    private func prepareChannel(connected: Bool, generation requested: UInt64) -> Bool {
        clearStoppedChannel()
        guard connected else {
            if channel != nil { invalidateEvidenceAndRequestStop() }
            return true
        }
        guard requiresChannel else { return true }
        guard let profile = channelProfile else { evidence.invalidate(); return false }
        if let channel {
            // A prior invalidation may still be cleaning up. Do not open a
            // second listener or claim that phase evidence is available.
            return channel.phaseKey() != nil
        }
        do {
            guard isCurrent(requested) else { return false }
            beforeOpenChannelForTests?()
            guard isCurrent(requested) else { return false }
            let opened = try ClaudeLoopChannel(profile: profile)
            guard install(opened, generation: requested) else { return false }
            channel = opened
            if let key = opened.phaseKey() { evidence.start(key: key) }
            else { evidence.invalidate(); return false }
            return true
        } catch {
            evidence.invalidate()
            return false
        }
    }

    private func drain() -> ClaudeSourceEvents {
        var result = ClaudeSourceEvents(gap: pendingTransportGap, affectsAll: pendingTransportGap)
        pendingTransportGap = false
        guard let channel, channel.phaseKey() != nil else { return result }
        let batch = channel.drain()
        result.gap = result.gap || batch.gap
        result.affectsAll = result.affectsAll || batch.gap
        if batch.gap { evidence.invalidate() }
        for event in batch.events {
            // Any frame may have been emitted after an earlier Stop. Frame
            // arrival does not establish ordering, so its session is unknown.
            result.lifecycleSessions.insert(event.sessionID)
            guard event.kind == .phase else {
                result.ordinary.append(event)
                continue
            }
            if let fingerprint = event.fingerprint,
               let affected = evidence.observe(session: event.sessionID, toolID: event.toolID, fingerprint: fingerprint) {
                result.affectedSessions.formUnion(affected)
            } else {
                evidence.invalidate()
                result.affectsAll = true
            }
        }
        return result
    }

    struct ComparedSnapshots {
        let snapshot: ClaudeTaskSnapshot
        let changed: Set<String>
        let affectsAll: Bool
    }

    static func compareSnapshots(_ first: ClaudeTaskSnapshot, _ second: ClaudeTaskSnapshot,
                                 middle: ClaudeSourceEvents) -> ComparedSnapshots {
        let old = Dictionary(grouping: first.tasks, by: \.id)
        let new = Dictionary(grouping: second.tasks, by: \.id)
        var all = middle.gap || middle.affectsAll || first.sourceUncertain != second.sourceUncertain ||
            old.values.contains(where: { $0.count != 1 }) || new.values.contains(where: { $0.count != 1 })
        var changed = Set(old.keys).union(new.keys)
        changed.formUnion(first.terminalIDs.union(second.terminalIDs))
        changed.formUnion(first.neutralEndedIDs.union(second.neutralEndedIDs))
        changed.formUnion(first.interruptedIDs.union(second.interruptedIDs))
        changed.formUnion(first.titleHistoryOverflowIDs.union(second.titleHistoryOverflowIDs))
        changed = Set(changed.filter { id in
            old[id]?.first != new[id]?.first ||
                first.terminalIDs.contains(id) != second.terminalIDs.contains(id) ||
                first.neutralEndedIDs.contains(id) != second.neutralEndedIDs.contains(id) ||
                first.interruptedIDs.contains(id) != second.interruptedIDs.contains(id) ||
                first.titleHistoryOverflowIDs.contains(id) != second.titleHistoryOverflowIDs.contains(id)
        })
        for session in middle.affectedSessions.union(middle.lifecycleSessions) {
            guard let key = claudeSessionKey(session) else { all = true; continue }
            changed.insert("claude:" + key)
        }
        var safe = second
        safe.titleHistoryOverflowIDs.formUnion(first.titleHistoryOverflowIDs)
        if all {
            safe.terminalIDs.removeAll()
            safe.interruptedIDs.removeAll()
            safe.neutralEndedIDs.removeAll()
        } else {
            safe.terminalIDs.subtract(changed)
            safe.interruptedIDs.subtract(changed)
            safe.neutralEndedIDs.subtract(changed)
        }
        safe.tasks = second.tasks.map { task in
            guard all || changed.contains(task.id) else { return task }
            return TaskSnapshotMerger.merge(previous: [task], current: [], terminalIDs: [])[0]
        }
        return ComparedSnapshots(snapshot: safe, changed: changed, affectsAll: all)
    }

    private func invalidatedRead(_ requested: UInt64) -> ClaudeSourceRead {
        ClaudeSourceRead(generation: requested, connection: nil, outcome: .changed,
                         before: ClaudeSourceEvents(gap: true, affectsAll: true),
                         middle: ClaudeSourceEvents(gap: true, affectsAll: true),
                         after: ClaudeSourceEvents(gap: true, affectsAll: true),
                         final: ClaudeSourceEvents(gap: true, affectsAll: true),
                         earlierTasks: [], changedSessionIDs: [], changesAffectAll: true,
                         phaseUncertainSessions: [], phasePoisoned: true, channelUnavailable: true)
    }

    private func read(observedSince: Date, generation requested: UInt64) -> ClaudeSourceRead {
        lastObservationStartedAt = ProcessInfo.processInfo.systemUptime
        guard isCurrent(requested) else { return invalidatedRead(requested) }
        if processedGeneration != requested {
            invalidateEvidenceAndRequestStop()
            processedGeneration = requested
        }
        var state: ClaudeIntegration.ConnectionState?
        var outcome: ClaudeSourceOutcome = .changed
        var before = ClaudeSourceEvents()
        var middle = ClaudeSourceEvents()
        var after = ClaudeSourceEvents()
        var final = ClaudeSourceEvents()
        var drainedAfter = false
        var uncertain: Set<String> = []
        var earlierTasks: [MonitoredTask] = []
        var changedSessions: Set<String> = []
        var affectsAll = false
        var channelUnavailable = false
        do {
            let initial = try connection()
            guard isCurrent(requested) else { return invalidatedRead(requested) }
            state = initial
            if initial == .disconnected {
                _ = prepareChannel(connected: false, generation: requested)
                before = drain()
                sawEvents = false
                outcome = .disconnected
                guard isCurrent(requested) else { return invalidatedRead(requested) }
                if try connection() != initial { outcome = .changed }
            } else {
                let connected = initial == .connected && requiresChannel
                channelUnavailable = !prepareChannel(connected: connected, generation: requested)
                guard isCurrent(requested) else { return invalidatedRead(requested) }
                before = drain()
                let exists = try journalExists()
                guard isCurrent(requested) else { return invalidatedRead(requested) }
                if !exists && sawEvents {
                    reader.noteSourceLoss()
                    throw CocoaError(.fileReadNoSuchFile)
                }
                if exists {
                    sawEvents = true
                    let first = try reader.readSnapshot(observedSince: observedSince, phaseEvidence: evidence)
                    guard isCurrent(requested) else { return invalidatedRead(requested) }
                    middle = drain()
                    lastObservationStartedAt = ProcessInfo.processInfo.systemUptime
                    let second = try reader.readSnapshot(observedSince: observedSince, phaseEvidence: evidence)
                    guard isCurrent(requested) else { return invalidatedRead(requested) }
                    let compared = Self.compareSnapshots(first, second, middle: middle)
                    earlierTasks = first.tasks
                    changedSessions = compared.changed
                    affectsAll = compared.affectsAll
                    var latest = compared.snapshot
                    afterSecondReadForTests?()
                    after = drain()
                    drainedAfter = true
                    // A tool that the live channel does not classify can
                    // still resume a session after Stop. Read the journal a
                    // third time before publishing an ending; an event after
                    // the final read can only be noticed on a later poll.
                    if !latest.terminalIDs.isEmpty || !latest.neutralEndedIDs.isEmpty {
                        guard isCurrent(requested) else { return invalidatedRead(requested) }
                        lastObservationStartedAt = ProcessInfo.processInfo.systemUptime
                        let third = try reader.readSnapshot(observedSince: observedSince, phaseEvidence: evidence)
                        guard isCurrent(requested) else { return invalidatedRead(requested) }
                        let endingCheck = Self.compareSnapshots(second, third, middle: after)
                        changedSessions.formUnion(endingCheck.changed)
                        affectsAll = affectsAll || endingCheck.affectsAll
                        latest = endingCheck.snapshot
                        if affectsAll {
                            latest.terminalIDs.removeAll(); latest.interruptedIDs.removeAll(); latest.neutralEndedIDs.removeAll()
                        } else {
                            latest.terminalIDs.subtract(changedSessions)
                            latest.interruptedIDs.subtract(changedSessions)
                            latest.neutralEndedIDs.subtract(changedSessions)
                        }
                        latest.tasks = latest.tasks.map { task in
                            guard affectsAll || changedSessions.contains(task.id) else { return task }
                            return TaskSnapshotMerger.merge(previous: [task], current: [], terminalIDs: [])[0]
                        }
                    }
                    outcome = .snapshot(latest)
                    for task in latest.tasks where task.id.hasPrefix("claude:") {
                        let session = String(task.id.dropFirst(7))
                        if evidence.isSessionUncertain(session) { uncertain.insert(task.id) }
                    }
                } else {
                    outcome = .noEvents
                }
                if drainedAfter { final = drain() } else { after = drain() }
                guard isCurrent(requested) else { return invalidatedRead(requested) }
                if try connection() != initial {
                    outcome = .changed
                    invalidateEvidenceAndRequestStop()
                }
            }
        } catch ClaudeReadError.journalBusy {
            outcome = .failed(ClaudeReadError.journalBusy)
            if drainedAfter { final = drain() } else { after = drain() }
        } catch {
            outcome = .failed(error)
            if sawEvents { reader.noteSourceLoss() }
            invalidateEvidenceAndRequestStop()
            if drainedAfter { final = ClaudeSourceEvents(gap: true, affectsAll: true) }
            else { after = ClaudeSourceEvents(gap: true, affectsAll: true) }
        }
        let result = ClaudeSourceRead(generation: requested, connection: state, outcome: outcome,
                                      before: before, middle: middle, after: after, final: final,
                                      earlierTasks: earlierTasks, changedSessionIDs: changedSessions, changesAffectAll: affectsAll,
                                      phaseUncertainSessions: uncertain,
                                      phasePoisoned: evidence.poisoned, channelUnavailable: channelUnavailable)
        if case .changed = outcome { return result.invalidated() }
        return isCurrent(requested) ? result : result.invalidated()
    }
}
