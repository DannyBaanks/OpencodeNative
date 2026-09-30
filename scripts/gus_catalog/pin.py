#!/usr/bin/env python3
"""Resolve pinning metadata for GUS catalog entries from the Hugging Face API.

Runs in CI (the runner can reach huggingface.co; developer sandboxes may not).
For every entry in Catalog/models.json it records, without trusting the entry:

  revision        the repository commit (kept if the entry already pins one)
  filename        the Q4_K_M GGUF at that revision (exact name or pattern match)
  byte_count      from the LFS pointer at that revision
  sha256          the LFS object id at that revision (= SHA-256 of the file)
  gated / license from the repository card
  gguf            architecture, context length, KV geometry and the embedded
                  chat template, read from the GGUF header with an HTTP range
                  request (no weights are downloaded here)

Standard library only. Output: JSON to --out and a table on stdout.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://huggingface.co/api/models/"
RESOLVE = "https://huggingface.co/{repo}/resolve/{rev}/{path}"
HEADER_LIMIT = 96 * 1024 * 1024  # vocab arrays can be tens of MB before the template
UA = {"User-Agent": "isycodemovil-gus-catalog-pin/1"}

# GGUF value types
U8, I8, U16, I16, U32, I32, F32, BOOL, STR, ARR, U64, I64, F64 = range(13)
_SCALAR = {U8: "<B", I8: "<b", U16: "<H", I16: "<h", U32: "<I", I32: "<i",
           F32: "<f", BOOL: "<?", U64: "<Q", I64: "<q", F64: "<d"}


def _get_json(url: str) -> object:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


class _Stream:
    """Sequential reader over a ranged HTTP body, bounded by HEADER_LIMIT."""

    def __init__(self, url: str | None = None, fileobj=None):
        if fileobj is not None:            # local files: tests and offline checks
            self.resp = fileobj
        else:
            req = urllib.request.Request(url, headers={**UA, "Range": f"bytes=0-{HEADER_LIMIT - 1}"})
            self.resp = urllib.request.urlopen(req, timeout=120)
        self.read_bytes = 0

    def read(self, n: int) -> bytes:
        out = bytearray()
        while len(out) < n:
            chunk = self.resp.read(n - len(out))
            if not chunk:
                raise EOFError("GGUF header truncated")
            out += chunk
        self.read_bytes += n
        if self.read_bytes > HEADER_LIMIT:
            raise EOFError("GGUF header larger than the read limit")
        return bytes(out)

    def close(self) -> None:
        self.resp.close()


def _read_value(s: _Stream, vtype: int, keep: bool):
    if vtype in _SCALAR:
        fmt = _SCALAR[vtype]
        return struct.unpack(fmt, s.read(struct.calcsize(fmt)))[0]
    if vtype == STR:
        (n,) = struct.unpack("<Q", s.read(8))
        raw = s.read(n)
        return raw.decode("utf-8", "replace") if keep else None
    if vtype == ARR:
        (itype,) = struct.unpack("<I", s.read(4))
        (count,) = struct.unpack("<Q", s.read(8))
        items = []
        for _ in range(count):
            v = _read_value(s, itype, keep and count <= 64)
            if keep and count <= 64:
                items.append(v)
        return items if keep and count <= 64 else {"array_len": count}
    raise ValueError(f"unknown GGUF value type {vtype}")


def gguf_header(url: str | None = None, fileobj=None) -> dict:
    s = _Stream(url, fileobj)
    try:
        if s.read(4) != b"GGUF":
            raise ValueError("not a GGUF file")
        (version,) = struct.unpack("<I", s.read(4))
        _n_tensors, n_kv = struct.unpack("<QQ", s.read(16))
        kv: dict = {}
        for _ in range(n_kv):
            (klen,) = struct.unpack("<Q", s.read(8))
            key = s.read(klen).decode("utf-8", "replace")
            (vtype,) = struct.unpack("<I", s.read(4))
            keep = not key.startswith("tokenizer.ggml.")  # skip vocab payloads
            kv[key] = _read_value(s, vtype, keep)
        return {"version": version, "kv": kv, "header_bytes": s.read_bytes}
    finally:
        s.close()


def summarize_gguf(h: dict) -> dict:
    kv = h["kv"]
    arch = kv.get("general.architecture")
    g = lambda k: kv.get(f"{arch}.{k}")  # noqa: E731
    n_layer, n_head, n_head_kv = g("block_count"), g("attention.head_count"), g("attention.head_count_kv")
    n_embd = g("embedding_length")
    k_len = g("attention.key_length") or (n_embd // n_head if isinstance(n_embd, int) and isinstance(n_head, int) and n_head else None)
    v_len = g("attention.value_length") or k_len
    # head_count_kv may be a per-layer array on hybrid models; take the max (conservative).
    if isinstance(n_head_kv, list):
        n_head_kv = max(n_head_kv) if n_head_kv else None
    if isinstance(n_head_kv, dict):
        n_head_kv = None
    kv_per_token = None
    if all(isinstance(x, int) for x in (n_layer, n_head_kv, k_len, v_len)):
        kv_per_token = n_layer * n_head_kv * (k_len + v_len) * 2  # f16 K and V
    tmpl = kv.get("tokenizer.chat_template")
    return {
        "architecture": arch,
        "name": kv.get("general.name"),
        "context_length": g("context_length"),
        "block_count": n_layer,
        "kv_bytes_per_token": kv_per_token,
        "chat_template_sha256": hashlib.sha256(tmpl.encode()).hexdigest() if isinstance(tmpl, str) else None,
        "chat_template_head": tmpl[:240] if isinstance(tmpl, str) else None,
        "chat_template": tmpl if isinstance(tmpl, str) else None,
        "file_type": kv.get("general.file_type"),
        "gguf_version": h["version"],
    }


def resolve(entry: dict) -> dict:
    repo = entry["repository"]
    out: dict = {"id": entry["id"], "repository": repo}
    try:
        info = _get_json(API + repo)
    except urllib.error.HTTPError as e:
        return {**out, "status": "REPO_NOT_FOUND" if e.code in (401, 404) else f"HTTP_{e.code}"}
    rev = entry.get("revision") or info.get("sha")
    card = info.get("cardData") or {}
    out.update(revision=rev, gated=info.get("gated", False),
               license=card.get("license"), license_name=card.get("license_name"),
               license_link=card.get("license_link"))
    if out["gated"]:
        return {**out, "status": "GATED"}
    tree = _get_json(f"{API}{repo}/tree/{rev}?recursive=true")
    files = [f for f in tree if f.get("type") == "file" and f["path"].lower().endswith(".gguf")]
    want = entry.get("filename")
    if want:
        match = [f for f in files if f["path"] == want]
    else:
        pat = entry.get("file_pattern", "q4_k_m.gguf").lower()
        match = [f for f in files if f["path"].lower().endswith(pat) and "/" not in f["path"]]
    if len(match) != 1:
        return {**out, "status": "FILE_AMBIGUOUS" if match else "FILE_NOT_FOUND",
                "candidates": sorted(f["path"] for f in files)[:40]}
    f = match[0]
    lfs = f.get("lfs") or {}
    out.update(filename=f["path"], byte_count=lfs.get("size", f.get("size")), sha256=lfs.get("oid"))
    if entry.get("sha256") and entry["sha256"] != out["sha256"]:
        return {**out, "status": "PIN_MISMATCH", "expected_sha256": entry["sha256"]}
    url = RESOLVE.format(repo=repo, rev=rev, path=urllib.parse.quote(f["path"]))
    out["source_url"] = url
    try:
        out["gguf"] = summarize_gguf(gguf_header(url))
    except Exception as e:  # header problems are reported, never fatal to the batch
        return {**out, "status": "HEADER_ERROR", "error": str(e)[:200]}
    return {**out, "status": "OK"}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", default="Catalog/models.json")
    ap.add_argument("--out", default="gus-pins.json")
    ap.add_argument("--only", nargs="*", help="restrict to these ids")
    args = ap.parse_args(argv)
    catalog = json.loads(Path(args.catalog).read_text(encoding="utf-8"))
    entries = [e for e in catalog["models"] if not args.only or e["id"] in args.only]
    results = []
    for e in entries:
        try:
            r = resolve(e)
        except Exception as exc:
            r = {"id": e["id"], "repository": e["repository"], "status": "ERROR", "error": str(exc)[:200]}
        results.append(r)
        g = r.get("gguf") or {}
        print(f"{r['status']:15s} {r['id']:28s} {str(r.get('byte_count') or ''):>12s} "
              f"{str(g.get('architecture') or ''):12s} kv/tok={g.get('kv_bytes_per_token')} "
              f"lic={r.get('license')} {r.get('filename') or ''}", flush=True)
    Path(args.out).write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
