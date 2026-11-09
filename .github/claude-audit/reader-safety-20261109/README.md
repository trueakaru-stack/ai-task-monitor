# Claude reader safety candidate

These snapshots are test-only input for a disposable macOS runner. They are
not integrated into the application, a release, or an installer. The candidate
tries to avoid treating old plans or anomalously timed events as current.

Its stateless log reader cannot establish all event delivery or historical
ordering, and a task may remain unconfirmed after a clock anomaly. The user
chose progress labelled as based on observed steps when only list completeness
is uncertain; contradictory or stale step states hide progress. Phase-safety
and independent Unicode identity tests may fail and run without suppression.
No claim of live Claude Desktop, cloud, or real-agent validation is made.
