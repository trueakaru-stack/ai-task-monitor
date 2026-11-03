# Loop warning: Windows visual check

The reference is the existing AI Task Monitor WPF task card, compact task window, and settings controls, together with the agreed warning placement and dismiss action. The screenshots render the current source in WPF at 96 DPI with synthetic task data. No real task text is included.

Inspected the expanded and compact task views and the settings section in dark and light themes. The warning is below the activity text, its explanation and action fit, and the five visible plan rows remain available. Existing settings colors, control styles, and section spacing are reused. `Test-LoopUi.ps1` separately exercises the dismiss action and both ends of the settings ranges in the WPF control tree.

The previews do not establish real mouse or keyboard interaction, accessibility-reader behavior, high-DPI behavior, or macOS appearance. These still require checks in the actual application environment.
