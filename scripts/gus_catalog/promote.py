#!/usr/bin/env python3
"""Promote candidates to pinned entries from the gus-catalog workflow output.

  promote.py <proposals.json> [--only id ...] [--experimental-over-bytes N]

<proposals.json> is a JSON list of the `PROPOSAL {...}` lines printed by the
Smoke report job. Only candidates whose smoke run succeeded (status OK and a
correct answer) are promoted. Licenses are mapped from the Hugging Face card;
unknown or custom licenses are recorded as non-commercial until a human checks
them. CI cross-checks every pinned value against Hugging Face afterwards.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Catalog" / "models.json"

LICENSES = {
    "apache-2.0": ("Apache License 2.0", "https://www.apache.org/licenses/LICENSE-2.0", True),
    "mit": ("MIT License", "https://opensource.org/license/mit", True),
    "llama3.1": ("Llama 3.1 Community License", "https://www.llama.com/llama3_1/license/", True),
    "llama3.2": ("Llama 3.2 Community License", "https://www.llama.com/llama3_2/license/", True),
    "gemma": ("Gemma Terms of Use", "https://ai.google.dev/gemma/terms", True),
}
# Upstream licenses for mirrors whose card omits them (checked by hand).
KNOWN_UPSTREAM = {
    "gemma3-4b-q4km": "gemma",
    "phi4-mini-q4km": "mit",
}


def swift_name(model_id: str) -> str:
    parts = re.split(r"[^a-z0-9]+", model_id)
    return parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:] if p)


def promote(entry: dict, p: dict, experimental_over: int) -> dict:
    lic_key = KNOWN_UPSTREAM.get(entry["id"], p.get("license"))
    if lic_key in LICENSES:
        lic_name, lic_url, commercial = LICENSES[lic_key]
    else:
        lic_name = "Custom license (see model card) · verify before commercial use"
        lic_url = f"https://huggingface.co/{p['repository']}/blob/{p['revision']}/README.md"
        commercial = False
    uploader = p["repository"].split("/")[0]
    out = {
        "id": entry["id"],
        "swift_name": swift_name(entry["id"]),
        "status": "pinned",
        "name": entry["name"],
        "family": entry["family"],
        "vendor": entry["vendor"],
        "parameters": entry["parameters"],
        "repository": p["repository"],
        "filename": p["filename"],
        "revision": p["revision"],
        "byte_count": p["byte_count"],
        "sha256": p["sha256"],
        "license_name": lic_name,
        "license_url": lic_url,
        "commercial_use": commercial,
        "attribution": f"{entry['family']} model by {entry['vendor']}; GGUF by {uploader}",
        "chat_template": "auto",
        "experimental": p["byte_count"] > experimental_over,
        "evidence": "desktop-smoke",
    }
    for key in ("architecture", "kv_bytes_per_token", "context_length"):
        if p.get(key):
            out[key] = p[key]
    if p.get("template_source") == "fallback-chatml":
        out["notes"] = "Embedded chat template is not a llama.cpp builtin; ChatML fallback passed the smoke test."
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("proposals", type=Path)
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--experimental-over-bytes", type=int, default=1_600_000_000)
    args = ap.parse_args(argv)
    proposals = {p["id"]: p for p in json.loads(args.proposals.read_text(encoding="utf-8"))}
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    promoted, pinned_ids = [], set()
    for i, entry in enumerate(catalog["models"]):
        p = proposals.get(entry["id"])
        if entry["status"] == "pinned" and p and p.get("smoke") == "OK" and p.get("paris"):
            entry["evidence"] = "desktop-smoke"
        if entry["status"] != "candidate" or (args.only and entry["id"] not in args.only):
            continue
        if not p or p.get("status") != "OK" or p.get("smoke") != "OK" or not p.get("paris"):
            print(f"skip {entry['id']}: not resolved and smoke-tested")
            continue
        catalog["models"][i] = promote(entry, p, args.experimental_over_bytes)
        promoted.append(entry["id"])
        pinned_ids.add(entry["id"])
    lines = ['{', '  "schema": 1,',
             '  "notes": ' + json.dumps(catalog["notes"], ensure_ascii=False, indent=4).replace("\n", "\n  ") + ',',
             '  "models": [']
    rows = []
    for m in catalog["models"]:
        if m["status"] == "pinned":
            rows.append("    " + json.dumps(m, ensure_ascii=False, indent=2).replace("\n", "\n    "))
        else:
            rows.append("    " + json.dumps(m, ensure_ascii=False))
    lines += [",\n".join(rows), "  ]", "}", ""]
    CATALOG.write_text("\n".join(lines), encoding="utf-8")
    print(f"promoted {len(promoted)}: {' '.join(promoted)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
