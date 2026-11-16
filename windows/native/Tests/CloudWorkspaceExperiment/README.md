# Synthetic Codex Cloud working-directory feasibility

This hosted-only experiment tests whether a Windows directory ACL can prevent
a child running as the current user from creating a relative error.log while
still allowing that directory to be used as the child's working directory.
It uses a fresh runner-temp directory and a synthetic child executable; it does
not start Codex, read credentials, access cloud accounts or contact a network.

The experiment also creates the workspace atomically relative to an open parent
directory, rejects an existing directory, holds the new directory without delete
sharing, tests an attempted rename and removes the empty directory through its
open handle. It is not the product implementation: ancestry and substitution
races around process working-directory resolution are not fully addressed,
and permission and filesystem behavior on other Windows installations is
unverified. Directory ownership, atomic creation, cleanup on abnormal shutdown,
external processes and .NET Framework compatibility still require design and
tests before either released or native transport may rely on this approach.

The hosted runner uses a new synthetic output tree and isolated .NET state,
sets DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0 for parent and child SDK processes,
disables the ASP.NET certificate, does not set HOME or CODEX_HOME, and compares
process and persistent user/machine PATH before and after the test. Environment
markers are accidental-execution safeguards, not a security boundary. Never run
this fixture on a user computer.
