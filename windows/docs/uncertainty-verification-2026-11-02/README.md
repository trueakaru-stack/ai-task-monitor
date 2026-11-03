# Unconfirmed-task view: Windows visual check

The reference is the established Windows task card and compact view, together with the approved requirement to keep an observed task visible as `Статус не подтверждён` when its state is uncertain. The current WPF source was rendered at 96 DPI with synthetic task data in expanded and compact modes, using both dark and light themes. The screenshots show an unconfirmed Codex task alongside an active Claude Code task; the unconfirmed task is not included in the active counts and is marked with a neutral dot in compact mode.

The layout, provider labels, plan rows, progress display and existing colors were compared with the reference. No clipped status or task text was observed in these fixtures. These rendered snapshots do not verify real pointer or keyboard interaction, assistive technology, multi-monitor placement, non-96-DPI displays, or the native macOS interface.
