#!/usr/bin/env python3
"""Generate drop-in cat sprite packs for sprites/.

Reuses the built-in `cat` (Mochi) silhouette + walk cycle so geometry is known
good; each variant just swaps the palette and paints a few accent pixels.
Run from the repo root: python3 native/gen_cats.py
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPRITES = os.path.join(ROOT, "sprites")

# Base silhouette (16 wide). Chars: k outline, X body, p ear/nose pink,
# o/w eyes, d foot shadow, . transparent. `s` is a per-cat accent (stripes).
IDLE = [
    "..kk........kk..",
    ".kXXk......kXXk.",
    ".kXpXk....kXpXk.",
    ".kXXXXkkkkXXXXk.",
    ".kXXXXXXXXXXXXk.",
    "kXXXXXXXXXXXXXXk",
    "kXXooXXXXXXooXXk",
    "kXXowXXXXXXowXXk",
    "kXXXXXXkppkXXXXk",
    "kdXXXXXXXXXXXXdk",
    ".kXXXXXXXXXXXXk.",
    "..kXXXXXXXXXXk..",
    "..kXXXXXXXXXXk..",
    "..kdXXk..kXXdk..",
    "...kk......kk...",
]
# Walk cycle differs from idle only on the last (feet) row.
FEET_A = "..kk........kk.."
FEET_B = "....kk....kk...."


def overlay(rows, points):
    """Return rows with (row, col) -> char accents painted, but only over body
    pixels (never touches outline/eyes/transparent), so accents can't break the
    silhouette."""
    grid = [list(r) for r in rows]
    for r, c, ch in points:
        if grid[r][c] == "X":
            grid[r][c] = ch
    return ["".join(g) for g in grid]


# Tabby "M" forehead + back stripes, shared by the striped cats.
STRIPES = [
    (4, 5, "s"), (4, 7, "s"), (4, 8, "s"), (4, 10, "s"),   # forehead M
    (5, 3, "s"), (5, 12, "s"),                              # temples
    (10, 3, "s"), (10, 6, "s"), (10, 9, "s"), (10, 12, "s"),  # back
    (11, 4, "s"), (11, 7, "s"), (11, 10, "s"),               # lower back
]

CATS = {
    "orange-cat": {
        "name": "Tora",
        "emoji": "🐯",
        "palette": {"X": "#f0a04b", "s": "#d9812f", "d": "#c97b2e",
                    "o": "#26262e", "w": "#ffffff", "p": "#f7c8a0", "k": "#5a3a22"},
        "stripes": STRIPES,
    },
    "black-cat": {
        "name": "Kuro",
        "emoji": "🐈‍⬛",
        # Charcoal body so the darker outline still reads; amber eyes pop.
        "palette": {"X": "#3f3d4a", "s": "#4a4857", "d": "#2c2a35",
                    "o": "#f2c14e", "w": "#fff4c2", "p": "#e0819a", "k": "#232029"},
        "stripes": [],
    },
    "cream-cat": {
        "name": "Miso",
        "emoji": "🐱",
        "palette": {"X": "#f3e4c7", "s": "#e2c99b", "d": "#d8bd93",
                    "o": "#26262e", "w": "#ffffff", "p": "#f0a5bb", "k": "#8a7859"},
        "stripes": STRIPES,
    },
    "calico-cat": {
        "name": "Pumpkin",
        "emoji": "🐈",
        # Patches: `s` orange, `m` dark used as splotches over a cream base.
        "palette": {"X": "#f5ecd8", "s": "#eb9a4d", "m": "#4a4048", "d": "#d8bd93",
                    "o": "#26262e", "w": "#ffffff", "p": "#f0a5bb", "k": "#8a7859"},
        "stripes": [
            (3, 2, "m"), (3, 13, "s"),                      # ears: one dark one orange
            (4, 3, "m"), (4, 4, "m"), (5, 2, "m"),          # left dark patch
            (10, 9, "s"), (10, 10, "s"), (10, 11, "s"),     # right orange patch
            (11, 8, "s"), (11, 9, "s"), (12, 8, "s"),
        ],
    },
}


def build(spec):
    idle = overlay(IDLE, spec["stripes"])
    frame_a = idle[:-1] + [FEET_A]
    frame_b = idle[:-1] + [FEET_B]
    return {
        "name": spec["name"],
        "emoji": spec["emoji"],
        "palette": spec["palette"],
        "rows": idle,
        "walk": [frame_a, frame_b],
    }


def main():
    for key, spec in CATS.items():
        sprite = build(spec)
        # sanity: every row 16 wide, every char in palette or transparent.
        pal = set(spec["palette"]) | {"."}
        for label, rows in [("rows", sprite["rows"])] + \
                [(f"walk[{i}]", f) for i, f in enumerate(sprite["walk"])]:
            for ri, row in enumerate(rows):
                assert len(row) == 16, f"{key} {label} row {ri} width {len(row)}"
                bad = set(row) - pal
                assert not bad, f"{key} {label} row {ri} unknown chars {bad}"
        path = os.path.join(SPRITES, f"{key}.json")
        with open(path, "w") as f:
            json.dump(sprite, f, indent=2)
            f.write("\n")
        print(f"wrote {path}  ({spec['name']} {spec['emoji']})")


if __name__ == "__main__":
    main()
