# Synthetic WPF update-host experiment

This experiment connects the real Windows update service to the existing
WPF update dialog only through injected synthetic test inputs. The ordinary
preview does not create a release service, start a network request, detect a
distribution channel, or open a download. This is not a released updater.

The hosted test injects a fake HTTP handler that returns a synthetic release
list. It exercises the existing selector, service, dispatcher pump and
published dialog; the download action invokes a counter, not a browser or an
installer. A Store service must construct no external handler, and an unknown
channel must be rejected. The test checks deferral while compact, the existing
session-only dismissal, a new synthetic version, localization, and asynchronous
shutdown while fake handler disposal is blocked. Late synthetic responses must
not appear after shutdown.

The test writes eight synthetic frames under a new GitHub-hosted runner-temp
directory: Russian and English, light and dark, full and compact. Full frames
show the existing dialog; compact frames show the deferred state. These frames
do not constitute visual acceptance against the approved reference. No real
network, user settings, installation, package download or live update is tested.

A real integration remains blocked until all of the following are defined and
verified:

* one authoritative build-time version used by the C# application and its
  installation package;
* a trustworthy distinction between Store and standalone distributions;
* release asset identity, architecture and appropriate integrity/signature
  verification before offering anything as an installer;
* a tested owner for startup, periodic checks, shutdown and the approved
  download action in the complete application.

The existing legacy VersionInfo.cs describes the previous installer, not the
C# preview. The legacy Store marker is not produced by the new prototype
installer. The update selector currently accepts an executable extension and a
trusted GitHub URL; that does not establish that the asset is an installer.
The confirmed historic AITaskMonitorSetup-<version>.exe naming convention is
useful for a future contract but does not prove file contents or architecture.
The selector currently reads only the first GitHub release page.

The CI-only runner in .github/update-host-ci/Run.ps1 creates new synthetic
paths, supplies DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0 to every .NET process,
disables the ASP.NET development certificate, isolates child profile and cache
locations, and compares persistent user and machine PATH values and types plus
process PATH. It does not set HOME or CODEX_HOME. Hosted-runner environment
markers guard against accidents but are not an isolation boundary. Never run
the hosted WPF test on a user's computer.
