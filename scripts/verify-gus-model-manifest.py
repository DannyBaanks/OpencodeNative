#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
manifest = (root / "Sources/Model/GUSModelManifest.swift").read_text(encoding="utf-8")
expected = {
    "07800fcba6d5d1df3dfa36e3763374a2c0d9f91b": "pinned Hugging Face revision",
    "qwen1_5-1_8b-chat-q4_k_m.gguf": "fixed Q4_K_M filename",
    "1_217_752_928": "exact byte count",
    "702e983c77883426806a2af75d34ab3e462e1b822f9dc23b49e02280c24b2b18": "expected SHA-256",
    "https://huggingface.co/Qwen/Qwen1.5-1.8B-Chat-GGUF/resolve/": "direct pinned source URL",
}
missing = [label for value, label in expected.items() if value not in manifest]
if missing:
    print("::error::GUS model manifest is missing: " + ", ".join(missing), file=sys.stderr)
    raise SystemExit(1)

for path in root.rglob("*"):
    if path.is_file() and path.suffix.lower() == ".gguf" and ".git" not in path.parts and ".build" not in path.parts:
        print(f"::error::GGUF weights must not be checked into the repository: {path.relative_to(root)}", file=sys.stderr)
        raise SystemExit(1)

print("GUS model provenance manifest is pinned; no GGUF weights found in repository files.")
