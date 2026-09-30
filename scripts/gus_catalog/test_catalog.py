"""Unit tests for the GUS catalog tooling (stdlib only; no network)."""
from __future__ import annotations

import copy
import io
import json
import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import crosscheck  # noqa: E402
import generate  # noqa: E402
import pin  # noqa: E402
import promote  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "Catalog" / "models.json").read_text(encoding="utf-8"))


def _gguf_bytes(kv: list[tuple[str, int, object]]) -> bytes:
    def s(x: str) -> bytes:
        b = x.encode()
        return struct.pack("<Q", len(b)) + b
    out = b"GGUF" + struct.pack("<I", 3) + struct.pack("<QQ", 0, len(kv))
    for key, vtype, value in kv:
        out += s(key) + struct.pack("<I", vtype)
        if vtype == pin.STR:
            out += s(value)
        elif vtype == pin.U32:
            out += struct.pack("<I", value)
        elif vtype == pin.ARR:
            itype, items = value
            out += struct.pack("<IQ", itype, len(items))
            for it in items:
                out += s(it) if itype == pin.STR else struct.pack("<I", it)
    return out


class GenerateTests(unittest.TestCase):
    def test_repository_catalog_is_valid_and_generated_file_is_current(self):
        pinned = generate.validate(copy.deepcopy(CATALOG))
        self.assertGreaterEqual(len(pinned), 3)
        self.assertEqual(generate.OUTPUT.read_text(encoding="utf-8"), generate.render(pinned))

    def test_source_url_is_always_derived_from_huggingface(self):
        e = next(m for m in CATALOG["models"] if m["status"] == "pinned")
        url = generate.source_url(e)
        self.assertTrue(url.startswith(f"https://huggingface.co/{e['repository']}/resolve/{e['revision']}/"))

    def _broken(self, **changes):
        c = copy.deepcopy(CATALOG)
        entry = next(m for m in c["models"] if m["status"] == "pinned")
        entry.update(changes)
        with self.assertRaises(generate.CatalogError):
            generate.validate(c)

    def test_rejects_unsafe_or_incomplete_pins(self):
        self._broken(sha256="ABC")
        self._broken(revision="main")
        self._broken(filename="sub/dir.gguf")
        self._broken(filename="model.bin")
        self._broken(byte_count=0)
        self._broken(license_url="http://example.com")
        self._broken(chat_template="jinja-custom")
        self._broken(gated=True)
        self._broken(evidence="trust-me")
        self._broken(repository="https://evil.example/x")
        # The directive is sent verbatim into the system prompt: keep it tiny and plain.
        self._broken(thinking_off="<|im_start|>system")
        self._broken(thinking_off="x" * 80)
        self._broken(thinking_off=True)

    def test_reasoning_models_carry_a_thinking_off_directive(self):
        pinned = {m["id"]: m for m in generate.validate(copy.deepcopy(CATALOG))}
        for mid, model in pinned.items():
            if model.get("architecture") in {"qwen3", "smollm3", "nemotron_h"}:
                self.assertTrue(model.get("thinking_off"), mid)
        swift = generate.render(list(pinned.values()))
        self.assertIn('thinkingOffDirective: "/no_think"', swift)
        self.assertIn("thinkingOffDirective: nil", swift)

    def test_rejects_duplicate_ids(self):
        c = copy.deepcopy(CATALOG)
        c["models"].append(copy.deepcopy(c["models"][0]))
        with self.assertRaises(generate.CatalogError):
            generate.validate(c)

    def test_candidates_never_reach_swift(self):
        text = generate.render(generate.validate(copy.deepcopy(CATALOG)))
        for m in CATALOG["models"]:
            if m["status"] != "pinned":
                self.assertNotIn(m["repository"], text)

    def test_swift_int_grouping(self):
        self.assertEqual(generate._swift_int(491400032), "491_400_032")
        self.assertEqual(generate._swift_int(12), "12")


class GGUFHeaderTests(unittest.TestCase):
    def test_summarizes_kv_geometry_and_template(self):
        blob = _gguf_bytes([
            ("general.architecture", pin.STR, "llama"),
            ("general.name", pin.STR, "tiny"),
            ("llama.block_count", pin.U32, 16),
            ("llama.embedding_length", pin.U32, 2048),
            ("llama.attention.head_count", pin.U32, 32),
            ("llama.attention.head_count_kv", pin.U32, 8),
            ("llama.context_length", pin.U32, 131072),
            ("tokenizer.ggml.tokens", pin.ARR, (pin.STR, ["a"] * 100)),
            ("tokenizer.chat_template", pin.STR, "{{ '<|start_header_id|>' }}"),
        ])
        summary = pin.summarize_gguf(pin.gguf_header(fileobj=io.BytesIO(blob)))
        self.assertEqual(summary["architecture"], "llama")
        self.assertEqual(summary["kv_bytes_per_token"], 16 * 8 * (64 + 64) * 2)
        self.assertEqual(summary["context_length"], 131072)
        self.assertIn("start_header_id", summary["chat_template"])

    def test_hybrid_per_layer_kv_heads_use_the_maximum(self):
        blob = _gguf_bytes([
            ("general.architecture", pin.STR, "nemotron_h"),
            ("nemotron_h.block_count", pin.U32, 4),
            ("nemotron_h.embedding_length", pin.U32, 256),
            ("nemotron_h.attention.head_count", pin.U32, 4),
            ("nemotron_h.attention.head_count_kv", pin.ARR, (pin.U32, [0, 2, 0, 2])),
        ])
        summary = pin.summarize_gguf(pin.gguf_header(fileobj=io.BytesIO(blob)))
        self.assertEqual(summary["kv_bytes_per_token"], 4 * 2 * (64 + 64) * 2)

    def test_rejects_non_gguf_and_truncation(self):
        with self.assertRaises(ValueError):
            pin.gguf_header(fileobj=io.BytesIO(b"NOPE" + b"\0" * 32))
        with self.assertRaises(EOFError):
            pin.gguf_header(fileobj=io.BytesIO(_gguf_bytes([("general.architecture", pin.STR, "x")])[:-3]))


class PromoteTests(unittest.TestCase):
    def test_swift_names(self):
        self.assertEqual(promote.swift_name("nemotron-nano-9b-v2-q4km"), "nemotronNano9bV2Q4km")

    def test_unknown_license_is_not_commercial(self):
        entry = {"id": "x-q4km", "name": "X", "family": "X", "vendor": "V", "parameters": "1B"}
        p = {"repository": "o/r", "revision": "a" * 40, "filename": "x.gguf", "byte_count": 2_000_000_000,
             "sha256": "b" * 64, "license": "other"}
        out = promote.promote(entry, p, 1_600_000_000)
        self.assertFalse(out["commercial_use"])
        self.assertTrue(out["experimental"])
        self.assertIn("/blob/" + "a" * 40 + "/", out["license_url"])


class CrosscheckTests(unittest.TestCase):
    def _pins(self):
        out = []
        for e in CATALOG["models"]:
            if e["status"] == "pinned":
                out.append({"id": e["id"], "status": "OK", "revision": e["revision"], "filename": e["filename"],
                            "byte_count": e["byte_count"], "sha256": e["sha256"],
                            "gguf": {"architecture": e.get("architecture"),
                                     "kv_bytes_per_token": e.get("kv_bytes_per_token"),
                                     "context_length": e.get("context_length")}})
        return out

    def test_matching_pins_pass(self):
        self.assertEqual(crosscheck.crosscheck(CATALOG, self._pins()), [])

    def test_changed_hash_or_geometry_fails(self):
        pins = self._pins()
        pins[0]["sha256"] = "0" * 64
        pins[1]["gguf"]["kv_bytes_per_token"] = 1
        problems = crosscheck.crosscheck(CATALOG, pins)
        self.assertEqual(len(problems), 2)

    def test_unresolvable_pinned_entry_fails(self):
        pins = self._pins()
        pins[0] = {"id": pins[0]["id"], "status": "REPO_NOT_FOUND"}
        self.assertEqual(len(crosscheck.crosscheck(CATALOG, pins)), 1)


if __name__ == "__main__":
    unittest.main()
