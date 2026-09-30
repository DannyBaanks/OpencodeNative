#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]

# Catalog/models.json is the source of truth; the Swift catalog must match it.
check = subprocess.run([sys.executable, str(root / "scripts/gus_catalog/generate.py"), "--check"])
if check.returncode != 0:
    print("::error::Catalog/models.json and GUSModelCatalog.generated.swift disagree.", file=sys.stderr)
    raise SystemExit(1)

manifest = (root / "Sources/Model/GUSModelCatalog.generated.swift").read_text(encoding="utf-8")
# The originally approved artifacts must never change silently.
artifacts = {
    "qwen15-18b-q4km": [
        "07800fcba6d5d1df3dfa36e3763374a2c0d9f91b",
        "qwen1_5-1_8b-chat-q4_k_m.gguf", "1_217_752_928",
        "702e983c77883426806a2af75d34ab3e462e1b822f9dc23b49e02280c24b2b18",
        "Qwen/Qwen1.5-1.8B-Chat-GGUF", "JustinLin610", "Tongyi Qianwen",
    ],
    "qwen25-05b-q4km": [
        "9217f5db79a29953eb74d5343926648285ec7e67",
        "qwen2.5-0.5b-instruct-q4_k_m.gguf", "491_400_032",
        "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db",
        "Qwen/Qwen2.5-0.5B-Instruct-GGUF", "Apache License 2.0",
    ],
    "smollm2-360m-q4km": [
        "de67c694b3fa2c6e9b45b50f286b2555c5dee2a8",
        "smollm2-360m-instruct-q4_k_m.gguf", "270_590_528",
        "8856952e27c65a87618f8347d1d06328c3953af04e8327b6dd1fab6670358fd0",
        "mfuntowicz/SmolLM2-360M-Instruct-Q4_K_M-GGUF", "HuggingFaceTB",
        "mfuntowicz", "Apache License 2.0", "https://www.apache.org/licenses/LICENSE-2.0",
    ],
}
missing = [f"{model_id}: {value}" for model_id, values in artifacts.items()
           for value in values if value not in manifest]
if missing:
    print("::error::GUS model manifest is missing pinned metadata: " + "; ".join(missing), file=sys.stderr)
    raise SystemExit(1)

for path in root.rglob("*"):
    if (path.is_file() and path.suffix.lower() == ".gguf"
            and not {".git", ".build", "DerivedData"}.intersection(path.parts)):
        print(f"::error::GGUF weights must not be checked into the repository: {path.relative_to(root)}", file=sys.stderr)
        raise SystemExit(1)

print("Original GUS model pins intact; catalog generated file current; no GGUF weight files in repository.")
