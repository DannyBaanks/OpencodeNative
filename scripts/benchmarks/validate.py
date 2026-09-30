#!/usr/bin/env python3
"""Validate a GUS benchmark report (usually pasted in a GitHub issue) and store it.

  validate.py --issue-body body.md --issue 42 [--write]

The issue body is untrusted input. Only a strictly validated, re-serialized
subset of the JSON is ever written, under benchmarks/<model id>/.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = "isycode.gus.benchmark/1"
TASK_IDS = ["short-answer", "json-object", "long-prefill", "sustained-generation"]
STATUSES = {"completed", "failed", "killed"}
THERMAL = {"nominal", "fair", "serious", "critical", "unknown"}
MAX_BODY = 64 * 1024
# iOS reports the hardware id (iPhone13,2); Android reports manufacturer + model.
DEVICE_MODEL = {
    "ios": r"(iPhone|iPad|iPod|arm64|x86_64)[0-9A-Za-z,._-]{0,20}",
    "android": r"[A-Za-z0-9][A-Za-z0-9 ,._()+-]{1,60}",
}


class Invalid(ValueError):
    pass


def extract_json(body: str) -> dict:
    if len(body) > MAX_BODY:
        raise Invalid("issue body too large")
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", body, re.S)
    text = fenced.group(1) if fenced else body[body.find("{"): body.rfind("}") + 1]
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        raise Invalid(f"not valid JSON: {e.msg}") from None
    if not isinstance(data, dict):
        raise Invalid("JSON must be an object")
    return data


def _num(d: dict, key: str, lo: float, hi: float, optional: bool = False, integer: bool = False):
    v = d.get(key)
    if v is None and optional:
        return None
    if isinstance(v, bool) or not isinstance(v, (int, float)) or (integer and not isinstance(v, int)):
        raise Invalid(f"{key} must be a number")
    if not lo <= v <= hi:
        raise Invalid(f"{key}={v} out of range [{lo}, {hi}]")
    return v


def _str(d: dict, key: str, pattern: str, optional: bool = False):
    v = d.get(key)
    if v is None and optional:
        return None
    if not isinstance(v, str) or not re.fullmatch(pattern, v):
        raise Invalid(f"{key} has an unexpected format")
    return v


def load_catalog() -> dict[str, dict]:
    catalog = json.loads((ROOT / "Catalog" / "models.json").read_text(encoding="utf-8"))
    return {m["id"]: m for m in catalog["models"] if m["status"] == "pinned"}


def validate(data: dict, catalog: dict[str, dict], llama_commit: str) -> dict:
    """Returns a normalized copy containing only known fields."""
    if data.get("schema") != SCHEMA:
        raise Invalid(f"schema must be {SCHEMA}")
    if data.get("protocol") != 1:
        raise Invalid("unsupported benchmark protocol")
    status = data.get("status")
    if status not in STATUSES:
        raise Invalid("status must be completed, failed or killed")
    model, device = data.get("model"), data.get("device")
    if not isinstance(model, dict) or not isinstance(device, dict):
        raise Invalid("model and device are required")
    platform = device.get("platform", "ios")
    if platform not in DEVICE_MODEL:
        raise Invalid("device.platform must be ios or android")
    entry = catalog.get(model.get("id"))
    if entry is None:
        raise Invalid("model id is not a pinned catalog model")
    if model.get("sha256") != entry["sha256"] or model.get("byte_count") != entry["byte_count"]:
        raise Invalid("model sha256/byte_count do not match the catalog pin")
    if model.get("context_tokens") != 2048:
        raise Invalid("protocol v1 uses a 2048-token context")
    if data.get("llama_cpp_commit") != llama_commit:
        raise Invalid("report was produced with a different llama.cpp build")

    out = {
        "schema": SCHEMA, "protocol": 1, "status": status,
        "run_id": _str(data, "run_id", r"[0-9A-Fa-f-]{8,64}"),
        "created_at": _str(data, "created_at", r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"),
        "app_version": _str(data, "app_version", r"[0-9A-Za-z .()_-]{1,40}"),
        "llama_cpp_commit": llama_commit,
        "device": {
            "platform": platform,
            "model": _str(device, "model", DEVICE_MODEL[platform]),
            "os": _str(device, "os", r"[0-9A-Za-z .()_-]{1,60}"),
            "ram_bytes": _num(device, "ram_bytes", 1 << 30, 64 << 30, integer=True),
            "app_memory_limit_bytes": _num(device, "app_memory_limit_bytes", 0, 64 << 30, integer=True),
            "low_power_mode": bool(device.get("low_power_mode", False)),
        },
        "model": {"id": entry["id"], "sha256": entry["sha256"], "byte_count": entry["byte_count"], "context_tokens": 2048},
        "footprint_before_bytes": _num(data, "footprint_before_bytes", 0, 64 << 30, integer=True),
        "peak_footprint_bytes": _num(data, "peak_footprint_bytes", 0, 64 << 30, integer=True),
        "load_ms": _num(data, "load_ms", 0, 3_600_000, optional=True),
        "thermal_start": data.get("thermal_start") if data.get("thermal_start") in THERMAL else "unknown",
        "thermal_end": data.get("thermal_end") if data.get("thermal_end") in THERMAL else None,
        "stopped_during": _str(data, "stopped_during", r"load|task:[a-z-]{1,40}", optional=True),
        "tasks": [],
    }
    tasks = data.get("tasks")
    if not isinstance(tasks, list) or len(tasks) > len(TASK_IDS):
        raise Invalid("tasks must be a list of at most 4 entries")
    for i, t in enumerate(tasks):
        if not isinstance(t, dict) or t.get("id") != TASK_IDS[i]:
            raise Invalid(f"task {i} must be {TASK_IDS[i]}")
        out["tasks"].append({
            "id": t["id"],
            "prompt_tokens": _num(t, "prompt_tokens", 0, 8192, integer=True),
            "generated_tokens": _num(t, "generated_tokens", 0, 512, integer=True),
            "prefill_tok_s": _num(t, "prefill_tok_s", 0, 100_000),
            "gen_tok_s": _num(t, "gen_tok_s", 0, 10_000),
            "template": t.get("template") if t.get("template") in {"override", "embedded", "fallbackChatML"} else "unknown",
            "stopped_at_eot": bool(t.get("stopped_at_eot", False)),
            "passed": bool(t.get("passed", False)),
        })
    if status == "completed" and len(out["tasks"]) != len(TASK_IDS):
        raise Invalid("a completed run must contain all 4 tasks")
    return out


def llama_commit() -> str:
    text = (ROOT / "scripts" / "build-llama-xcframework.sh").read_text(encoding="utf-8")
    return re.search(r'LLAMA_COMMIT="([0-9a-f]{40})"', text).group(1)


def destination(report: dict) -> Path:
    device = re.sub(r"[^0-9A-Za-z]+", "-", report["device"]["model"]).strip("-")
    return ROOT / "benchmarks" / report["model"]["id"] / f"{device}-{report['run_id'][:8].lower()}.json"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--issue-body", type=Path, required=True)
    ap.add_argument("--issue", type=int, default=0)
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args(argv)
    try:
        report = validate(extract_json(args.issue_body.read_text(encoding="utf-8")), load_catalog(), llama_commit())
    except Invalid as e:
        print(f"INVALID: {e}")
        return 1
    if args.issue:
        report["source_issue"] = args.issue
    dest = destination(report)
    print(f"VALID: {report['model']['id']} on {report['device']['model']} ({report['status']}) -> {dest.relative_to(ROOT)}")
    if args.write:
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
