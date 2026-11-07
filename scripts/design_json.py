#!/usr/bin/env python3
"""Prints the setDesign JSON for one face, e.g. `design_json.py rotor black` (same as the iPhone sends)."""
import json, pathlib, sys
root = pathlib.Path(__file__).resolve().parent.parent
spec_id, pal_id = sys.argv[1], sys.argv[2]
spec = next(s for s in json.loads((root / "faces/specs.json").read_text()) if s["id"] == spec_id)
AURORA = {"id": "aurora", "name": "Aurora", "bg1": "#1B1E4B", "bg2": "#05060F", "accent": "#2ED1DB", "ink": "#FFFFFF"}
pal = next((p for p in spec.get("own", []) if p["id"] == pal_id), AURORA)
body = {k: v for k, v in spec.items() if k not in ("id", "name", "blurb", "pal", "own")}
print(json.dumps({"id": f"{spec_id}-{pal_id}", "name": f"{spec['name']} {pal['name']}", "layout": "spec",
                  "bg1": pal["bg1"], "bg2": pal["bg2"], "accent": pal["accent"], "ink": pal["ink"], "spec": body}))
