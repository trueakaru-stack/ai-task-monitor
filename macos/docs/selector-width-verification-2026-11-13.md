# Settings selector width verification

This record covers only the six retention and repeat-check selectors and the
two journal buttons in the settings screen. It does not approve the rest of
the application or replace the requested full visual review and video.

The reference was the existing `macos` source at `db0f80c689ea7fbd5dbe8b7e27e9c4be8943ea98`,
rendered with the same synthetic preview hooks as the candidate. The user asked
for equal-width selectors sized from the widest option and unchanged journal
button sizes. The original clipboard screenshot files are no longer available,
so exact pixel comparison to those files was not possible.

The candidate in [hosted run 43478398349](https://github.com/trueakaru-stack/ai-task-monitor/actions/runs/43478398349)
used `SettingsView.swift` with SHA-256
`59875899d67bf56f7eab8cc3bad636d0a2d6a002cc64e0d95e7869d73a5fcfc0`.
It was rendered at 560 × 700 points and 1× on macOS 15 with Xcode 16.1 and on
macOS 26. Both Russian and English, light and dark appearances, and initial,
minimum, maximum and widest-value selections were captured. The synthetic
bindings did not update the user's settings or start real providers. Only the
disposable runner's standard defaults were read by the preview store.
The run artifacts `settings-width-macos-15` and `settings-width-macos-26`
contain the `settings-width-<language>-<theme>-<state>.png` screenshots and
matching geometry reports; GitHub's artifact retention applies.

The six visible selector frames had equal widths and aligned right edges in
the recorded states. Manual inspection of the candidate screenshots found the
displayed labels readable in the widest selections, and the examined minimum
and maximum selections showed the intended values. The two journal-button
layout bounds matched the baseline for each language and appearance. A
calibrated pixel-coordinate check also passed its unchanged-frame control.
The macOS 15 and 26 controls retain their respective native visual styles.

This evidence covers the inspected controls only. The recorded screen is scrolled to the settings
section; the bottom feedback address is clipped by that viewport. macOS 13 and
14, higher display scales, keyboard focus, hover, disabled/error states, actual
settings persistence, the complete screen and comparison against the original
clipboard files were not checked. These limitations remain open for the final
application review.
