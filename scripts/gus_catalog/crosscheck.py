#!/usr/bin/env python3
"""Fail if a pinned catalog entry disagrees with what Hugging Face serves.

Input is the output of pin.py. Candidates are reported but never fail the run
(their repository names are guesses until resolved); pinned entries must match
exactly, because the app downloads and trusts them.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def crosscheck(catalog: dict, pins: list[dict]) -> list[str]:
    by_id = {p["id"]: p for p in pins}
    problems = []
    for e in catalog["models"]:
        if e["status"] != "pinned" or e["id"] not in by_id:
            continue
        p = by_id[e["id"]]
        if p.get("status") != "OK":
            problems.append(f"{e['id']}: resolver status {p.get('status')}")
            continue
        for field in ("revision", "filename", "byte_count", "sha256"):
            if e[field] != p.get(field):
                problems.append(f"{e['id']}: {field} catalog={e[field]!r} hf={p.get(field)!r}")
        g = p.get("gguf") or {}
        for field, key in (("architecture", "architecture"), ("kv_bytes_per_token", "kv_bytes_per_token"),
                           ("context_length", "context_length")):
            if field in e and g.get(key) is not None and e[field] != g[key]:
                problems.append(f"{e['id']}: {field} catalog={e[field]!r} gguf={g[key]!r}")
    return problems


def main(argv: list[str]) -> int:
    pins = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
    catalog = json.loads((ROOT / "Catalog" / "models.json").read_text(encoding="utf-8"))
    problems = crosscheck(catalog, pins)
    for p in problems:
        print(f"::error::{p}")
    for p in pins:
        if p.get("status") != "OK":
            print(f"::notice::{p['id']}: {p.get('status')} {p.get('candidates', '')}")
    print(f"{len(problems)} problem(s) in pinned entries")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
