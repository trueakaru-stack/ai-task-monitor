# Isolated native update retry policy

This .NET 10 library is an unconnected migration slice. It computes retry
delays from caller-supplied HTTP header values and keeps an in-memory monotonic
schedule. It does not make network requests, read or write settings, open
downloads, start PowerShell, or connect to the application.

Successful checks schedule the next check no sooner than 24 hours. Failed
checks use a bounded exponential retry. Both respect `Retry-After` and rate
limit hints.
Numeric hints that cannot be represented, and values beyond the 64 KiB input
limit, disable automatic retries for the lifetime of the in-memory schedule.
Where an absolute hint has no valid server `Date`, the policy
uses the supplied local time and a 24-hour floor; an incorrectly fast local
clock can still cause an early retry. The schedule is not persisted, so
restarting the app clears it, including any disabled-retry sentinel.

The schedule must be accessed serially, with a single request in flight, a
consistent positive monotonic clock frequency, and stale request generations
filtered by the caller. `Record` returns false before the current deadline;
it rejects the entire early result, including any longer server hint that it
contains. That guard is not a substitute for single-flight request control.
If the monotonic counter resets while an admitted request is in flight, its
result can also be rejected as early. The controller must detect and handle
that reset without discarding the result or a longer server hint; simply
ignoring a false return can shorten the requested delay.
The constructor accepting a previous failure count allows a controller to
retain a streak when it resets a schedule after detecting a clock reset. It
accepts only counts from zero through six; it does not restore a prior deadline.
The caller must also bound the number of supplied headers and handle transport
errors, cancellation and shutdown. No UI responsiveness or real network
behavior is established by this library.

The delay calculation uses .NET 10's HTTP date parser; unusual dates may
behave differently from Windows PowerShell's .NET Framework parser. The
impossible legacy failure count `Int32.MinValue` is safely clamped here, while
the reference throws. Invalid monotonic frequencies are rejected. The owning
controller must distinguish an unavailable or invalid result from a successful
check without an update.

## Synthetic verification

On Windows, use Python 3.9 or later, Git, Windows PowerShell 5.1, an isolated
.NET 10 SDK and the pinned `windows/app/ReleaseUpdates.ps1` reference:

```powershell
python .\windows\native\UpdateRetry\Tests\run_synthetic_tests.py `
  --sdk-root '<isolated-sdk-directory>' `
  --reference-file '<checkout>/windows/app/ReleaseUpdates.ps1' `
  --work-directory '<directory outside the repository and user profile>'
```

The runner rejects output inside the checkout, the current profile and app
data directories, and existing HOME and CODEX_HOME directories when supplied.
It creates a unique synthetic work directory, disables package sources and
.NET first-run certificate generation, and does not assign HOME or CODEX_HOME.
Its path guard relies on the environment and does not prove
protection from other profiles, alternate aliases or concurrent link changes.
It does not enforce an operating-system network block.

The final synthetic run compared 611 header cases with the actual extracted
PowerShell functions and exercised initial, successful, early-result and
counter-reset deadlines. An independent review of the matching policy ran
3,000 additional comparisons with varied times and 2,055 boundary/clock
assertions, including an arbitrary-precision oracle for fractional deadlines.
The tests do not establish real requests, system sleep, crash recovery, all
HTTP date forms, or integration with the window or installer.
