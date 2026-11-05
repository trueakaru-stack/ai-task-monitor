#!/usr/bin/env python3
"""Compare synthetic hit probes with the instrumented baseline on the same runner."""

import json
import pathlib
import sys


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Expected: compare-scroll-fixed.py <runner-temp>.")
    temporary = pathlib.Path(sys.argv[1])
    names = ("baseline", "fixed-before", "fixed-after")
    output = temporary / "aitm-layout-fixed-comparison"
    output.mkdir(parents=True, exist_ok=True)
    expected = {(theme, x, y) for theme in ("light", "dark")
                for x in ("left", "center", "right") for y in ("low", "center", "high")}
    datasets = {}
    errors = []
    for variant in names:
        file = temporary / ("aitm-layout-fixed-" + variant) / "fixed-hit-tests.json"
        try:
            rows = json.loads(file.read_text(encoding="utf-8"))
            data = {(row["theme"], row["xBand"], row["yBand"]): row for row in rows}
            if len(rows) != 18 or set(data) != expected:
                raise ValueError("expected the complete set of 18 unique points")
            datasets[variant] = data
        except (OSError, ValueError, KeyError, TypeError) as error:
            errors.append({"variant": variant, "error": str(error)})
    comparisons = []
    if len(datasets) == len(names):
        for variant in names[1:]:
            for key in sorted(expected):
                baseline, candidate = datasets["baseline"][key], datasets[variant][key]
                before, after = baseline["buttonFrame"], candidate["buttonFrame"]
                same_frame = len(before) == len(after) == 4 and all(abs(a - b) <= 0.5 for a, b in zip(before, after))
                hit_preserved = not baseline["dismissed"] or candidate["dismissed"]
                comparisons.append({"variant": variant, "theme": key[0], "xBand": key[1], "yBand": key[2],
                                    "baselineHit": baseline["dismissed"], "candidateHit": candidate["dismissed"],
                                    "sameFrame": same_frame, "hitPreserved": hit_preserved})
                if not same_frame or not hit_preserved:
                    errors.append({"variant": variant, "point": key, "sameFrame": same_frame, "hitPreserved": hit_preserved})
    result = {"status": "failed" if errors else "passed", "errors": errors, "comparisons": comparisons}
    (output / "fixed-hit-comparison.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": result["status"], "points": len(comparisons), "errors": len(errors)}))
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
