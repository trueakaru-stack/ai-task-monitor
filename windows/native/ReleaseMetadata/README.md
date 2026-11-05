# Isolated native release metadata selector

This .NET 10 library is an **unconnected migration slice**. It validates
caller-supplied public release metadata, compares versions, selects a matching
platform's installer and checks its GitHub release URL. It performs no network
requests, downloads, scheduling, Store checks, settings access or UI actions.

`Inspect.Valid` distinguishes a valid response without an update from an
invalid response. The selector accepts up to 1,048,576 UTF-16 code units and
supports stable versions and prereleases with numeric identifiers. Build
metadata is not supported. Version and asset paths use the same ASCII limits as
the corrected Windows updater.

The library intentionally rejects some inputs tolerated by the legacy
PowerShell parser: nonstandard JSON, invalid Unicode anywhere in the tree,
case-colliding property names, repeated required fields, overflowing numbers,
excessive nesting and URLs whose original path must be normalized to match.
An exact repeat of an unknown property is allowed, but every value is checked.
These restrictions may reject unusual responses previously accepted; they are
not proof of compatibility with arbitrary malformed input.

One synthetic near-limit input allocated approximately 32 MiB cumulatively in
an independent run; this is not a resource bound. The future application must
bound the received bytes before parsing, run selection away from the UI thread,
handle cancellation and stale results, and retain separate retry and Store
policies. Existing application behavior is unchanged by this library.

## Synthetic verification

Use Python 3.9 or newer, Git, an isolated .NET 10 SDK and Windows PowerShell
5.1. These are test tools only; the library has no Git, PowerShell or Python
runtime dependency. Run the tests from a Git checkout or worktree, with
absolute paths to the SDK, reference and work directory. From the repository
root:

```powershell
python .\windows\native\ReleaseMetadata\Tests\run_synthetic_tests.py `
  --sdk-root '<isolated-sdk-directory>' `
  --reference-file '<checkout-of-windows-app-source>/ReleaseUpdates.ps1' `
  --work-directory '<new-directory-outside-repository-and-user-profile>'
```

Before creating any work directory, the runner discovers the source repository
through a local Git query and rejects paths inside it. `USERPROFILE`, `APPDATA`
and `LOCALAPPDATA` must each name an existing absolute directory; `HOME`, if
present, must meet the same requirement. The runner resolves these directories
and rejects work paths inside them. If the repository or a required directory
cannot be verified, it stops without creating the work directory. Extended and
device path forms are rejected before creating output.

The profile guard relies on these environment variables. It does not identify
other users' profiles, prove that the variables were not deliberately changed,
guarantee detection of alternate path aliases (such as short names or mapped
drives), or protect against a junction being swapped concurrently after
validation. Use a trusted local work directory outside all profiles and
repositories.

The runner checks the SHA-256 of the normalized `ReleaseUpdates.ps1` from
Windows commit `ade7894`, copies it into an isolated work directory, disables
SDK telemetry and first-run certificate generation, clears NuGet feeds, and
compares 2,512 synthetic responses with the PowerShell helpers. Direct checks
cover prerelease ordering, malformed data, Unicode, numeric overflow, input
bounds and unsafe URLs. An independent review compared another 4,146 cases,
with 26 documented intentional strict differences, and separately checked 32
unsafe URLs. Real GitHub responses, transport, retry behavior, application
integration, physical input and installers remain unverified by this library.
