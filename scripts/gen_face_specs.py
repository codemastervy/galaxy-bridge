#!/usr/bin/env python3
"""Embeds faces/specs.json into the iPhone app (FaceSpecsData.swift). Run after editing specs."""
import json, pathlib, sys
root = pathlib.Path(__file__).resolve().parent.parent
specs = json.loads((root / "faces/specs.json").read_text())
ids = [s["id"] for s in specs]
assert len(ids) == len(set(ids)), "duplicate spec id"
for s in specs:
    assert 1 <= len(s["els"]) <= 160, s["id"]
    assert len(json.dumps(s)) < 24000, s["id"]
compact = json.dumps(specs, separators=(",", ":"), ensure_ascii=False)
out = root / "ios-app/GalaxyBridge/FaceSpecsData.swift"
out.write_text("// Generated from faces/specs.json by scripts/gen_face_specs.py. Do not edit.\n"
               "let faceSpecsJSON = #\"\"\"\n" + compact + "\n\"\"\"#\n")
print(f"{len(specs)} specs -> {out.relative_to(root)}")
