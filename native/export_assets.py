#!/usr/bin/env python3
"""Export sprite + species data from the Python pet into native/assets.json.

The Python files stay the single source of truth for pixel art and species
metadata; the Swift app loads this JSON at startup. Re-run after editing
PIXELS (pet_window.py) or SPECIES (pet.py):

    python3 native/export_assets.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pet
import pet_window


def _clusters(row):
    """[(start, end)] spans of non-'.' pixels in a row string."""
    spans, start = [], None
    for i, ch in enumerate(row + "."):
        if ch != "." and start is None:
            start = i
        elif ch == "." and start is not None:
            spans.append((start, i))
            start = None
    return spans


def _shift_row(row, moves):
    """Rebuild a row shifting each cluster by its move (clipped to bounds)."""
    w = len(row)
    out = ["."] * w
    for (a, b), dx in moves:
        for i in range(a, b):
            j = min(max(i + dx, 0), w - 1)
            out[j] = row[i]
    return "".join(out)


def make_walk_frames(rows):
    """Two-frame walk cycle: feet APART, then feet TOGETHER (scamper).

    Only the bottom row (the feet) moves; left cluster(s) step outward/inward
    mirrored by the right ones. Species whose bottom row is one solid cluster
    (slime-likes) get a 1px side-to-side waddle instead.
    """
    feet = rows[-1]
    spans = _clusters(feet)
    mid = len(feet) / 2
    if len(spans) >= 2:
        apart = _shift_row(feet, [(s, -1 if (s[0] + s[1]) / 2 < mid else 1) for s in spans])
        together = _shift_row(feet, [(s, 1 if (s[0] + s[1]) / 2 < mid else -1) for s in spans])
    else:  # single blob: waddle
        apart = _shift_row(feet, [(s, -1) for s in spans])
        together = _shift_row(feet, [(s, 1) for s in spans])
    return [rows[:-1] + [apart], rows[:-1] + [together]]


out = {"order": list(pet.SPECIES), "species": {}}
for key, px in pet_window.PIXELS.items():
    meta = pet.SPECIES.get(key, {})
    entry = {
        "name": meta.get("name", key.title()),
        "emoji": meta.get("emoji", ""),
        "palette": px["palette"],
        "rows": px["rows"],
    }
    if key != "egg":  # the egg wobbles procedurally; it has no feet
        entry["walk"] = make_walk_frames(px["rows"])
    out["species"][key] = entry

dest = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets.json")
with open(dest, "w") as f:
    json.dump(out, f, indent=1)
print("wrote %s (%d sprites)" % (dest, len(out["species"])))
