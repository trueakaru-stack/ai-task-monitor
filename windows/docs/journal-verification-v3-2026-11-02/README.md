# Journal visual verification

Date: 2026-11-02. The screenshots contain synthetic tasks and diagnostic events only.

- Reference: the existing Windows settings views in `screenshots/settings-dark.png` and `screenshots/settings-light.png`, plus the user's approved in-window journal, two compact selectors, and inline clearing confirmation.
- Renderer: the current PowerShell/WPF application, captured with `RenderTargetBitmap` at 590 × 760 and 96 DPI. The dropdown images capture each popup's WPF content separately.
- Inspected in both dark and light themes: settings and retention selectors, open dropdown, inline clearing confirmation, the journal, task filter dropdown, a filtered event list, and the initial viewport of an overflowing list. The final row may be partially visible at the scroll viewport edge.
- The first capture clipped the clearing confirmation. The final capture scrolls the journal section into view and shows both confirmation actions. The journal filter shows only the selected synthetic task.
- The screenshots do not establish actual popup placement near screen edges, mouse hover, keyboard navigation, screen-reader behaviour, or all DPI and window sizes. Computer Use did not expose the temporary WPF window, so these interaction checks remain unverified. Native macOS rendering was not tested.
