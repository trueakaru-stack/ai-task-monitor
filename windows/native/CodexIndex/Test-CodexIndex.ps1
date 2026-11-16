param(
    [string]$SdkRoot,
    [string]$WorkDirectory,
    [string]$ReferenceSource,
    [string]$WindowsPowerShell
)

# This legacy launcher cannot satisfy the hosted-only test executable's
# isolation contract. Fail before touching any supplied paths or environment.
throw 'The legacy Codex index test launcher is disabled. Use the disposable hosted workflow codex-index-bounded-synthetic-20261116.yml.'
