#!/usr/bin/env python3
"""Render pin + smoke results as a Markdown table (for the workflow summary)
and print one compact JSON line per model (for promoting candidates).

  report.py <gus-pins.json> <artifacts dir containing smoke-*/smoke-*.json>
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def gib(n: int | None) -> str:
    return f"{n / 1024**3:.2f}" if n else ""


def render(pins: list[dict], smokes: dict[str, dict]) -> str:
    rows = ["| id | pin | GiB | arch | kv/tok | template | smoke | gen tok/s | RSS GiB | Paris | repeat greedy→chat |",
            "|---|---|---:|---|---:|---|---|---:|---:|---|---|"]
    for p in pins:
        g = p.get("gguf") or {}
        s = smokes.get(p["id"], {})
        loop = (f"{s['greedy_repeat']:.2f}→{s['sampled_repeat']:.2f}"
                if "greedy_repeat" in s and "sampled_repeat" in s else "")
        rows.append("| {id} | {st} | {gb} | {arch} | {kv} | {tmpl} | {smoke} | {tps} | {rss} | {paris} | {loop} |".format(
            id=p["id"], st=p.get("status"), gb=gib(p.get("byte_count")), arch=g.get("architecture") or "",
            kv=g.get("kv_bytes_per_token") or "", tmpl=s.get("template_source", ""),
            smoke=s.get("status", "—"), tps=s.get("gen_tok_s", ""), rss=gib(s.get("max_rss_bytes")),
            paris={True: "yes", False: "no"}.get(s.get("mentions_paris"), ""), loop=loop))
    return "\n".join(["## GUS catalog resolution", "", *rows, "",
                      "Desktop CPU numbers only. Phone evidence comes from the in-app benchmark.", ""])


def proposal(p: dict, s: dict) -> dict:
    g = p.get("gguf") or {}
    return {
        "id": p["id"], "status": p.get("status"), "repository": p.get("repository"),
        "filename": p.get("filename"), "revision": p.get("revision"), "byte_count": p.get("byte_count"),
        "sha256": p.get("sha256"), "license": p.get("license"), "license_name": p.get("license_name"),
        "architecture": g.get("architecture"), "kv_bytes_per_token": g.get("kv_bytes_per_token"),
        "context_length": g.get("context_length"),
        "template_head": (g.get("chat_template_head") or "")[:100],
        "smoke": s.get("status"), "template_source": s.get("template_source"), "gen_tok_s": s.get("gen_tok_s"),
        "max_rss_bytes": s.get("max_rss_bytes"), "paris": s.get("mentions_paris"),
        "output": (s.get("output") or "")[:120],
        "greedy_repeat": s.get("greedy_repeat"), "sampled_repeat": s.get("sampled_repeat"),
        "sampled_output": (s.get("sampled_output") or "")[:160],
    }


def main(argv: list[str]) -> int:
    pins = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
    smokes = {}
    for f in Path(argv[2]).glob("smoke-*/smoke-*.json"):
        r = json.loads(f.read_text(encoding="utf-8"))
        smokes[r["id"]] = r
    print(render(pins, smokes))
    # The job log gets the machine-readable lines; stdout above goes to the step summary.
    for p in pins:
        print("PROPOSAL " + json.dumps(proposal(p, smokes.get(p["id"], {})), ensure_ascii=False, sort_keys=True),
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
