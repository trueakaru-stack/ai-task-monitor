# Update dialog visual verification

The images were rendered by the current WPF source at 590 × 760 pixels and 96 DPI with synthetic tasks and a synthetic release. The supplied update-dialog image is the information hierarchy and shadow reference; the existing app supplies the theme, system accent, and continuous-corner geometry. Both light and dark previews were inspected for the requested copy, action order, borderless action separation and clipping. The tests also exercise session dismissal, compact deferral, an asynchronous synthetic response and rejection of an untrusted download URL.

These previews do not verify hover, keyboard focus, screen-reader behavior, all DPI scales, or actual installation of an update.
