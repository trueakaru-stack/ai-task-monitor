using System;
using System.Collections.Generic;

namespace AITaskMonitor.CodexAgentLedger {
    // The source adapter must independently verify every claim. This model has
    // no access to Codex, the filesystem, a journal, or an agent's turn status.
    public enum EvidenceKind { Observed = 0, TurnCompleted = 1, ExplicitClose = 2, Restarted = 3 }
    public enum ApplyResult { Accepted, NoChange, IgnoredStale, NotTracked, Unverified, Conflict, Capacity, Invalid }

    [Flags]
    public enum Incompleteness {
        None = 0,
        CoverageUnverified = 1,
        SourceUnavailable = 2,
        UnverifiedEvidence = 4,
        ConflictingEvidence = 8,
        CapacityExceeded = 16,
        MissingEvidence = 32,
        InvalidEvidence = 64,
        TaskRetired = 128
    }

    public sealed class Evidence {
        public readonly Guid TaskId, ParentId, ChildId;
        public readonly string TaskIncarnation, ChildIncarnation;
        public readonly long ChildGeneration;
        public readonly EvidenceKind Kind;
        public readonly bool IdentityVerified, ParentChainVerified, EventVerified;

        // TaskIncarnation identifies the verified lifetime of the user's task,
        // not an ordinary chat turn, plan stage, refresh, or assistant turn.
        // ParentChainVerified means the entire chain to TaskId, including the
        // immediate ParentId, was independently verified for this incarnation.
        // ChildGeneration must be a source-verified, monotonically increasing
        // generation for ChildId, not a file timestamp or observation order.
        // EventVerified for ExplicitClose requires a verified successful close
        // of that child in that task incarnation. A turn ending or a raw DB
        // "closed" value alone does not prove that close completed.
        public Evidence(Guid taskId, string taskIncarnation, Guid parentId, Guid childId,
                        string childIncarnation, long childGeneration, EvidenceKind kind,
                        bool identityVerified, bool parentChainVerified, bool eventVerified) {
            TaskId = taskId; TaskIncarnation = taskIncarnation; ParentId = parentId; ChildId = childId;
            ChildIncarnation = childIncarnation; ChildGeneration = childGeneration; Kind = kind;
            IdentityVerified = identityVerified; ParentChainVerified = parentChainVerified; EventVerified = eventVerified;
        }
    }

    public sealed class CountSnapshot {
        internal CountSnapshot(bool tracked, int count, Incompleteness reasons) {
            IsTracked = tracked; KnownUnclosedCount = count; Reasons = reasons;
        }
        public bool IsTracked { get; private set; }
        public int KnownUnclosedCount { get; private set; }
        public Incompleteness Reasons { get; private set; }
        public bool IsComplete { get { return IsTracked && Reasons == Incompleteness.None; } }
    }

    public sealed class Ledger {
        private sealed class Agent {
            public Guid ParentId;
            public string Incarnation;
            public long Generation;
            public bool Closed, Conflicted;
        }
        private sealed class TaskState {
            public Guid Root;
            public readonly Dictionary<Guid, Agent> Agents = new Dictionary<Guid, Agent>();
            public Incompleteness Reasons;
        }

        private readonly object gate = new object();
        private readonly int maximumTasks, maximumAgentsPerTask, maximumRetiredTasks;
        private readonly Dictionary<string, TaskState> tasks = new Dictionary<string, TaskState>(StringComparer.Ordinal);
        private readonly HashSet<string> retiredTasks = new HashSet<string>(StringComparer.Ordinal);
        private bool taskCapacityExceeded, retirementCapacityExceeded;

        public Ledger() : this(64, 512) { }
        public Ledger(int maximumTasks, int maximumAgentsPerTask) {
            if (maximumTasks < 1 || maximumTasks > 256) throw new ArgumentOutOfRangeException("maximumTasks");
            if (maximumAgentsPerTask < 1 || maximumAgentsPerTask > 2048) throw new ArgumentOutOfRangeException("maximumAgentsPerTask");
            this.maximumTasks = maximumTasks; this.maximumAgentsPerTask = maximumAgentsPerTask;
            this.maximumRetiredTasks = maximumTasks * 4;
        }

        public bool RetirementCapacityExceeded { get { lock (gate) return retirementCapacityExceeded; } }

        // A true coverageVerified requires proof that no agent belonging to
        // this task incarnation was omitted. Absence of records is not proof.
        // Once coverage is lost it stays incomplete for this ledger's lifetime.
        public bool TrackTask(Guid taskId, string taskIncarnation, bool identityVerified, bool coverageVerified) {
            if (!ValidTask(taskId, taskIncarnation)) return false;
            lock (gate) {
                string key = Key(taskId, taskIncarnation);
                TaskState state;
                if (retiredTasks.Contains(key)) return false;
                if (tasks.TryGetValue(key, out state)) {
                    if (!identityVerified) state.Reasons |= Incompleteness.UnverifiedEvidence;
                    return identityVerified;
                }
                if (!identityVerified) return false;
                if (tasks.Count >= maximumTasks) { taskCapacityExceeded = true; return false; }
                state = new TaskState { Root = taskId };
                if (!coverageVerified) state.Reasons |= Incompleteness.CoverageUnverified;
                tasks.Add(key, state);
                return true;
            }
        }

        public bool MarkSourceUnavailable(Guid taskId, string taskIncarnation) {
            if (!ValidTask(taskId, taskIncarnation)) return false;
            lock (gate) {
                TaskState state;
                if (!tasks.TryGetValue(Key(taskId, taskIncarnation), out state)) return false;
                state.Reasons |= Incompleteness.SourceUnavailable;
                return true;
            }
        }

        // Free a completed task only after the source owner confirms the task
        // lifetime ended and all its in-flight reads are quiescent. A normal
        // completed turn is not task retirement. Never discard unknown coverage,
        // conflicting identity, or an agent without its own confirmed close.
        // Bounded tombstones reject delayed re-registration of the same task.
        public bool TryRetireTask(Guid taskId, string taskIncarnation,
                                  bool identityVerified, bool taskLifetimeEnded, bool sourceQuiescent) {
            if (!ValidTask(taskId, taskIncarnation) || !identityVerified || !taskLifetimeEnded || !sourceQuiescent) return false;
            lock (gate) {
                string key = Key(taskId, taskIncarnation);
                TaskState state;
                if (!tasks.TryGetValue(key, out state) || state.Reasons != Incompleteness.None) return false;
                foreach (Agent agent in state.Agents.Values) if (!agent.Closed || agent.Conflicted) return false;
                if (retiredTasks.Count >= maximumRetiredTasks) { retirementCapacityExceeded = true; return false; }
                retiredTasks.Add(key);
                tasks.Remove(key);
                taskCapacityExceeded = false;
                return true;
            }
        }

        public CountSnapshot Snapshot(Guid taskId, string taskIncarnation) {
            if (!ValidTask(taskId, taskIncarnation))
                return new CountSnapshot(false, 0, Incompleteness.InvalidEvidence);
            lock (gate) {
                TaskState state;
                string key = Key(taskId, taskIncarnation);
                if (retiredTasks.Contains(key)) return new CountSnapshot(false, 0, Incompleteness.TaskRetired);
                if (!tasks.TryGetValue(key, out state))
                    return new CountSnapshot(false, 0, taskCapacityExceeded ? Incompleteness.CapacityExceeded : Incompleteness.CoverageUnverified);
                int count = 0;
                foreach (Agent agent in state.Agents.Values) if (!agent.Closed) count++;
                return new CountSnapshot(true, count, state.Reasons);
            }
        }

        public ApplyResult Apply(Evidence evidence) {
            if (evidence == null || !ValidTask(evidence.TaskId, evidence.TaskIncarnation)) return ApplyResult.Invalid;
            lock (gate) {
                TaskState state;
                if (!tasks.TryGetValue(Key(evidence.TaskId, evidence.TaskIncarnation), out state)) return ApplyResult.NotTracked;
                if (evidence.ParentId == Guid.Empty || evidence.ChildId == Guid.Empty ||
                    evidence.ChildId == evidence.TaskId || evidence.ChildId == evidence.ParentId ||
                    !ValidToken(evidence.ChildIncarnation) || evidence.ChildGeneration < 1 ||
                    evidence.Kind < EvidenceKind.Observed || evidence.Kind > EvidenceKind.Restarted) {
                    state.Reasons |= Incompleteness.InvalidEvidence;
                    return ApplyResult.Invalid;
                }
                if (!evidence.IdentityVerified || !evidence.ParentChainVerified || !evidence.EventVerified) {
                    state.Reasons |= Incompleteness.UnverifiedEvidence;
                    return ApplyResult.Unverified;
                }
                if (HasConflictedAncestor(state, evidence.ParentId)) {
                    Agent claimed;
                    if (state.Agents.TryGetValue(evidence.ChildId, out claimed)) claimed.Conflicted = true;
                    state.Reasons |= Incompleteness.ConflictingEvidence;
                    return ApplyResult.Conflict;
                }

                Agent current;
                if (!state.Agents.TryGetValue(evidence.ChildId, out current)) {
                    if (evidence.Kind == EvidenceKind.TurnCompleted) {
                        state.Reasons |= Incompleteness.MissingEvidence;
                        return ApplyResult.NoChange;
                    }
                    if (state.Agents.Count >= maximumAgentsPerTask) {
                        state.Reasons |= Incompleteness.CapacityExceeded;
                        return ApplyResult.Capacity;
                    }
                    if (ConflictsWithOtherTask(state, evidence) || CreatesCycle(state, evidence.ParentId, evidence.ChildId)) {
                        state.Reasons |= Incompleteness.ConflictingEvidence;
                        return ApplyResult.Conflict;
                    }
                    state.Agents.Add(evidence.ChildId, new Agent { ParentId = evidence.ParentId,
                        Incarnation = evidence.ChildIncarnation, Generation = evidence.ChildGeneration,
                        Closed = evidence.Kind == EvidenceKind.ExplicitClose });
                    return ApplyResult.Accepted;
                }

                if (evidence.ChildGeneration < current.Generation) return ApplyResult.IgnoredStale;
                if (evidence.ChildGeneration == current.Generation) {
                    if (evidence.ParentId != current.ParentId || !String.Equals(evidence.ChildIncarnation, current.Incarnation, StringComparison.Ordinal)) {
                        current.Conflicted = true;
                        state.Reasons |= Incompleteness.ConflictingEvidence;
                        return ApplyResult.Conflict;
                    }
                    if (evidence.Kind == EvidenceKind.ExplicitClose) {
                        if (current.Conflicted) return ApplyResult.Conflict;
                        if (current.Closed) return ApplyResult.NoChange;
                        current.Closed = true;
                        return ApplyResult.Accepted;
                    }
                    if ((evidence.Kind == EvidenceKind.Restarted || evidence.Kind == EvidenceKind.Observed) && current.Closed) {
                        // A later observation could be a delayed replay or an
                        // unproven restart. Do not make either claim as fact.
                        state.Reasons |= Incompleteness.UnverifiedEvidence;
                        return ApplyResult.Unverified;
                    }
                    // A turn ending or duplicate observation must not change
                    // the count. A verified restart needs a new generation.
                    return ApplyResult.NoChange;
                }

                if (evidence.Kind != EvidenceKind.Restarted ||
                    String.Equals(evidence.ChildIncarnation, current.Incarnation, StringComparison.Ordinal)) {
                    state.Reasons |= Incompleteness.UnverifiedEvidence;
                    return ApplyResult.Unverified;
                }
                if (ConflictsWithOtherTask(state, evidence) || CreatesCycle(state, evidence.ParentId, evidence.ChildId)) {
                    current.Conflicted = true;
                    state.Reasons |= Incompleteness.ConflictingEvidence;
                    return ApplyResult.Conflict;
                }
                current.ParentId = evidence.ParentId;
                current.Incarnation = evidence.ChildIncarnation;
                current.Generation = evidence.ChildGeneration;
                current.Closed = false;
                current.Conflicted = false;
                return ApplyResult.Accepted;
            }
        }

        private bool ConflictsWithOtherTask(TaskState state, Evidence evidence) {
            bool conflict = false;
            foreach (TaskState other in tasks.Values) {
                if (other.Root == state.Root) continue; // Same chat, different verified task incarnation.
                Agent prior;
                if (!other.Agents.TryGetValue(evidence.ChildId, out prior)) continue;
                if (prior.Closed && evidence.Kind == EvidenceKind.Restarted &&
                    evidence.ChildGeneration > prior.Generation &&
                    !String.Equals(evidence.ChildIncarnation, prior.Incarnation, StringComparison.Ordinal)) continue;
                prior.Conflicted = true;
                other.Reasons |= Incompleteness.ConflictingEvidence;
                conflict = true;
            }
            return conflict;
        }

        private static bool CreatesCycle(TaskState state, Guid parentId, Guid childId) {
            Guid cursor = parentId;
            var traversed = new List<Agent>();
            for (int depth = 0; depth <= state.Agents.Count; depth++) {
                if (cursor == childId) {
                    foreach (Agent agent in traversed) agent.Conflicted = true;
                    return true;
                }
                if (cursor == state.Root) return false;
                Agent parent;
                if (!state.Agents.TryGetValue(cursor, out parent)) return false;
                traversed.Add(parent);
                cursor = parent.ParentId;
            }
            foreach (Agent agent in traversed) agent.Conflicted = true;
            return true;
        }

        private static bool HasConflictedAncestor(TaskState state, Guid parentId) {
            Guid cursor = parentId;
            for (int depth = 0; depth <= state.Agents.Count; depth++) {
                if (cursor == state.Root) return false;
                Agent parent;
                if (!state.Agents.TryGetValue(cursor, out parent)) return false;
                if (parent.Conflicted) return true;
                cursor = parent.ParentId;
            }
            return true;
        }

        private static bool ValidTask(Guid taskId, string incarnation) { return taskId != Guid.Empty && ValidToken(incarnation); }
        private static bool ValidToken(string token) {
            if (String.IsNullOrEmpty(token) || token.Length > 128) return false;
            foreach (char c in token) {
                if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                      (c >= '0' && c <= '9') || c == ':' || c == '_' || c == '-' || c == '.' || c == '/')) return false;
            }
            return true;
        }
        private static string Key(Guid taskId, string incarnation) { return taskId.ToString("D") + "/" + incarnation; }
    }
}
