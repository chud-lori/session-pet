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

out = {"order": list(pet.SPECIES), "species": {}}
for key, px in pet_window.PIXELS.items():
    meta = pet.SPECIES.get(key, {})
    out["species"][key] = {
        "name": meta.get("name", key.title()),
        "emoji": meta.get("emoji", ""),
        "palette": px["palette"],
        "rows": px["rows"],
    }

dest = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets.json")
with open(dest, "w") as f:
    json.dump(out, f, indent=1)
print("wrote %s (%d sprites)" % (dest, len(out["species"])))
