# Tooltip verification

Reference: the user's 2026-11-01 compact-window screenshot and the existing tooltip colors, border, text and geometry. The user clarified on 2026-11-02 that the tooltip should appear above the mouse pointer and shift to remain on screen.

The screenshots use synthetic task text. The application renders its own WPF window and tooltip into a synthetic dark background; the Windows arrow is drawn at the simulated pointer position. The user's desktop and real task information are not captured. The full and compact snapshots use 590 × 760 and 390 × 162 WPF window pixels respectively, rendered at 96 DPI.

Reviewed: dark and light themes, full and compact windows, truncated activity text, and the tooltip above the simulated pointer. The original shadow was clipped at the popup bounds and produced translucent square corners; the revised tooltip reserves transparent space for the shadow. Automated WPF tests check short and wrapped text, placement at screen edges, negative coordinates, and zero alpha along the outer bitmap edges in both themes. Actual mouse hover, keyboard focus, screen reader, multiple monitors, and other DPI scales still require verification; Computer Use did not expose the temporary application window.
