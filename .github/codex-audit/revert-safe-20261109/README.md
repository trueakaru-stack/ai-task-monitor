# Codex revert candidate audit

These are isolated test inputs, not shipped application sources. The two source
files and new test suite are copied from the 2026-11-09 candidate; the existing
synthetic suites use canonical UUID rollout names. The cloud fixture uses
`AITM_FIXTURE_DIR` for its temporary shell inputs rather than setting `HOME`;
its assertions are unchanged.

The baseline preview uses a test-only method that shows the existing full
Codex-source warning. Candidate previews use the proposed partial-source
warning. The additional fixed preview applies `RootView.swift`, which expands
the task area to keep the empty-screen heading and settings aligned with the
populated screen. All three use the same synthetic fixtures and rendering code.
The baseline shim is applied only inside the disposable CI checkout. Frames
are not live agent sessions, and the audit does not create or publish an
installer.
