import Foundation

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
    var affectsAll = false
}

struct ClaudeSourceRead {
    let generation: UInt64
    let connection: ClaudeIntegration.ConnectionState?
    let outcome: ClaudeSourceOutcome
    let before: ClaudeSourceEvents
    let middle: ClaudeSourceEvents
    let after: ClaudeSourceEvents
    let phaseUncertainSessions: Set<String>
    let phasePoisoned: Bool
    let channelUnavailable: Bool

    func invalidated() -> ClaudeSourceRead {
        ClaudeSourceRead(generation: generation, connection: nil, outcome: .changed,
                         before: ClaudeSourceEvents(gap: true, affectsAll: true),
                         middle: ClaudeSourceEvents(gap: true, affectsAll: true),
                         after: ClaudeSourceEvents(gap: true, affectsAll: true),
                         phaseUncertainSessions: [], phasePoisoned: true, channelUnavailable: true)
    }
}

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
    private var channel: ClaudeLoopChannel?
    private var evidence = ClaudePhaseEvidence()
    private var sawEvents = false
    private var processedGeneration: UInt64 = 0
    private var pendingTransportGap = false
    private var lastObservationStartedAt: TimeInterval = 0

    init(reader: ClaudeTaskReader, channelProfile: URL?, requiresChannel: Bool,
         beforeOpenChannelForTests: (() -> Void)? = nil,
         beforeDeliveryForTests: (() -> Void)? = nil,
         connection: @escaping () throws -> ClaudeIntegration.ConnectionState) {
        self.reader = reader
        self.channelProfile = channelProfile
        self.requiresChannel = requiresChannel
        self.beforeOpenChannelForTests = beforeOpenChannelForTests
        self.beforeDeliveryForTests = beforeDeliveryForTests
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
            guard event.kind == .phase else { result.ordinary.append(event); continue }
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

    private func snapshotsAgree(_ first: ClaudeTaskSnapshot, _ second: ClaudeTaskSnapshot) -> Bool {
        let old = Dictionary(grouping: first.tasks, by: \.id)
        let new = Dictionary(grouping: second.tasks, by: \.id)
        guard old.keys.count == new.keys.count, old.allSatisfy({ key, tasks in
            tasks.count == 1 && new[key]?.count == 1 && new[key]?.first == tasks.first
        }) else { return false }
        return first.terminalIDs == second.terminalIDs && first.interruptedIDs == second.interruptedIDs &&
            first.neutralEndedIDs == second.neutralEndedIDs && first.sourceUncertain == second.sourceUncertain &&
            first.titleHistoryOverflowIDs == second.titleHistoryOverflowIDs
    }

    private func invalidatedRead(_ requested: UInt64) -> ClaudeSourceRead {
        ClaudeSourceRead(generation: requested, connection: nil, outcome: .changed,
                         before: ClaudeSourceEvents(gap: true, affectsAll: true),
                         middle: ClaudeSourceEvents(gap: true, affectsAll: true),
                         after: ClaudeSourceEvents(gap: true, affectsAll: true),
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
        var uncertain: Set<String> = []
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
                let exists = FileManager.default.fileExists(atPath: reader.eventFile.path)
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
                    outcome = snapshotsAgree(first, second) ? .snapshot(second) : .changed
                    for task in second.tasks where task.id.hasPrefix("claude:") {
                        let session = String(task.id.dropFirst(7))
                        if evidence.isSessionUncertain(session) { uncertain.insert(task.id) }
                    }
                } else {
                    outcome = .noEvents
                }
                after = drain()
                guard isCurrent(requested) else { return invalidatedRead(requested) }
                if try connection() != initial {
                    outcome = .changed
                    invalidateEvidenceAndRequestStop()
                }
            }
        } catch ClaudeReadError.journalBusy {
            outcome = .failed(ClaudeReadError.journalBusy)
            after = drain()
        } catch {
            outcome = .failed(error)
            invalidateEvidenceAndRequestStop()
            after = ClaudeSourceEvents(gap: true, affectsAll: true)
        }
        let result = ClaudeSourceRead(generation: requested, connection: state, outcome: outcome,
                                      before: before, middle: middle, after: after, phaseUncertainSessions: uncertain,
                                      phasePoisoned: evidence.poisoned, channelUnavailable: channelUnavailable)
        if case .changed = outcome { return result.invalidated() }
        return isCurrent(requested) ? result : result.invalidated()
    }
}
