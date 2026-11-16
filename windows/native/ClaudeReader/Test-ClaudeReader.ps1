param(
    [string]$SdkRoot,
    [string]$WorkDirectory,
    [string]$PwshNet10,
    [string]$WindowsPowerShell
)

# This legacy launcher cannot verify the differing reader implementations.
# Fail before touching any supplied paths or environment.
throw 'The legacy Claude reader test launcher is disabled. Use the disposable hosted workflow claude-reader-behavior-20261116.yml.'
