"""Unit tests for benchmark intake and aggregation (stdlib only)."""
from __future__ import annotations

import copy
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import aggregate  # noqa: E402
import validate  # noqa: E402

CATALOG_FILE = validate.ROOT / "Catalog" / "models.json"
CATALOG = json.loads(CATALOG_FILE.read_text(encoding="utf-8"))
PINNED = validate.load_catalog()
COMMIT = validate.llama_commit()
MODEL = PINNED["qwen25-05b-q4km"]


def sample(status: str = "completed") -> dict:
    tasks = [{"id": t, "prompt_tokens": 40, "generated_tokens": 20, "prefill_tok_s": 250.5,
              "gen_tok_s": 30.25, "template": "embedded", "stopped_at_eot": True, "passed": True}
             for t in validate.TASK_IDS]
    return {
        "schema": validate.SCHEMA, "protocol": 1, "status": status,
        "run_id": "0A1B2C3D-0000-4000-8000-000000000000", "created_at": "2026-09-30T10:00:00Z",
        "app_version": "0.1.0 (1)", "llama_cpp_commit": COMMIT,
        "device": {"model": "iPhone13,2", "os": "Version 18.6 (Build 22G86)", "ram_bytes": 4 << 30,
                   "app_memory_limit_bytes": 3 << 30, "low_power_mode": False},
        "model": {"id": MODEL["id"], "sha256": MODEL["sha256"], "byte_count": MODEL["byte_count"], "context_tokens": 2048},
        "footprint_before_bytes": 100 << 20, "peak_footprint_bytes": 900 << 20, "load_ms": 1500.0,
        "thermal_start": "nominal", "thermal_end": "fair", "tasks": tasks if status == "completed" else tasks[:1],
        "stopped_during": None if status == "completed" else "task:json-object",
    }


class ValidateTests(unittest.TestCase):
    def test_accepts_exported_report_from_fenced_issue_body(self):
        body = "### Benchmark JSON\n\n```json\n" + json.dumps(sample()) + "\n```\n\n### Notes\n\ncase off"
        out = validate.validate(validate.extract_json(body), PINNED, COMMIT)
        self.assertEqual(out["model"]["id"], MODEL["id"])
        self.assertEqual(len(out["tasks"]), 4)
        self.assertTrue(str(validate.destination(out)).endswith("benchmarks/qwen25-05b-q4km/iPhone13-2-0a1b2c3d.json"))

    def test_killed_runs_may_be_partial(self):
        out = validate.validate(sample("killed"), PINNED, COMMIT)
        self.assertEqual(out["status"], "killed")
        self.assertEqual(out["stopped_during"], "task:json-object")

    def _reject(self, mutate):
        data = sample()
        mutate(data)
        with self.assertRaises(validate.Invalid):
            validate.validate(data, PINNED, COMMIT)

    def test_rejects_tampered_or_foreign_reports(self):
        self._reject(lambda d: d.update(schema="other/1"))
        self._reject(lambda d: d["model"].update(sha256="0" * 64))
        self._reject(lambda d: d["model"].update(id="not-in-catalog"))
        self._reject(lambda d: d.update(llama_cpp_commit="f" * 40))
        self._reject(lambda d: d["device"].update(model="<script>"))
        self._reject(lambda d: d["tasks"][3].update(gen_tok_s=1e9))
        self._reject(lambda d: d["tasks"].reverse())
        self._reject(lambda d: d["tasks"].pop())  # completed needs all tasks
        self._reject(lambda d: d.update(peak_footprint_bytes="big"))
        self._reject(lambda d: d["model"].update(context_tokens=4096))

    def test_accepts_android_devices(self):
        data = sample()
        data["device"].update(platform="android", model="Google Pixel 8", os="Android 15 (API 35)")
        out = validate.validate(data, PINNED, COMMIT)
        self.assertEqual(out["device"]["platform"], "android")
        self.assertTrue(str(validate.destination(out)).endswith("Google-Pixel-8-0a1b2c3d.json"))
        data["device"]["model"] = "<script>"
        with self.assertRaises(validate.Invalid):
            validate.validate(data, PINNED, COMMIT)
        data["device"].update(platform="symbian", model="Nokia")
        with self.assertRaises(validate.Invalid):
            validate.validate(data, PINNED, COMMIT)

    def test_unknown_fields_are_dropped(self):
        data = sample()
        data["prompt_text"] = "secret"
        data["tasks"][0]["output"] = "secret"
        out = validate.validate(data, PINNED, COMMIT)
        self.assertNotIn("secret", json.dumps(out))

    def test_rejects_non_json_and_huge_bodies(self):
        with self.assertRaises(validate.Invalid):
            validate.extract_json("no json here")
        with self.assertRaises(validate.Invalid):
            validate.extract_json("{" + " " * (validate.MAX_BODY + 1) + "}")


class AggregateTests(unittest.TestCase):
    def test_empty_table_explains_how_to_contribute(self):
        text = aggregate.render([], CATALOG)
        self.assertIn("No results yet", text)

    def test_groups_by_model_and_device(self):
        done = validate.validate(sample(), PINNED, COMMIT)
        killed = validate.validate(sample("killed"), PINNED, COMMIT)
        other = copy.deepcopy(done)
        other["tasks"][3]["gen_tok_s"] = 40.25
        text = aggregate.render([done, other, killed], CATALOG)
        row = next(line for line in text.splitlines() if line.startswith("|") and "iPhone13,2" in line)
        self.assertIn("| 3 | 2 | 1 |", row)
        self.assertIn("35.2", row)  # median of 30.25 and 40.25
        self.assertIn("8/8", row)

    def test_committed_benchmarks_page_is_current(self):
        self.assertEqual(aggregate.main(["--check"]), 0)


if __name__ == "__main__":
    unittest.main()
