# GUS model marketplace

GUS can run a range of small open models on the phone, with no network access once a model is downloaded. This page explains:

- how models get into the app;
- how the app decides what fits your device;
- how on-device benchmarks get published;
- what happens when the app crashes.

## Catalog

`Catalog/models.json` is the only list of models the app knows.

- **`pinned` entries** are compiled into `Sources/Model/GUSModelCatalog.generated.swift` by `scripts/gus_catalog/generate.py`. The app never downloads a catalog at runtime. The pinned SHA-256 is what authorizes a GGUF file, and malformed GGUF files have caused llama.cpp vulnerabilities before.
- **`candidate` entries** name a Hugging Face repository only. They never reach the app.

Each pinned model carries:

- repository, revision, filename, byte count and SHA-256;
- license, and whether commercial use is allowed;
- the KV-cache bytes per token read from the GGUF header, which drives the memory estimate;
- an optional builtin chat template override;
- an `experimental` flag and an evidence level:
  - `unmeasured`
  - `desktop-smoke`
  - `device-measured`

### Adding a model

1. Add a `candidate` entry with `id`, `name`, `family`, `vendor`, `parameters` and `repository`.
2. Open a PR. The **GUS model catalog** workflow runs three jobs:
   - **Bridge + catalog checks** builds the pinned llama.cpp on Linux and compiles the app's real `GUSLlamaBridge.c`. It checks chat framing and control-token neutralization against every llama.cpp vocab file.
   - **Resolve pins** reads the revision, size, SHA-256, license, architecture, context length, KV geometry and chat template from Hugging Face.
   - **Smoke** downloads each model, verifies the hash and generates an answer with the app's bridge. The job log prints one `PROPOSAL {…}` line per model.
3. Copy the proposal into the entry and set `status: pinned`. Then run `python3 scripts/gus_catalog/generate.py`.

Once an entry is pinned, CI cross-checks it against Hugging Face on every run. A changed hash, size, revision or KV geometry fails the build.

Gated repositories are rejected, because the app downloads anonymously.

## What fits this device

The picker does not guess from the iPhone model name. At runtime, the app reads its own memory ceiling: the current footprint plus `os_proc_available_memory()`. It compares that ceiling with each model's estimated peak:

```
peak ≈ weights + KV bytes/token × context + 160 MB + 10% of weights
```

| Estimated peak / app limit | Badge | Where it appears |
|---|---|---|
| ≤ 70 % | Cabe bien | Recommended |
| 70–90 % | Justo | Recommended, confirmation before downloading |
| > 90 % | Probablemente no cabe | Experimental section |

Models flagged `experimental` in the catalog always go in the experimental section, which is hidden behind a toggle. Downloading one requires confirming an honest warning. The realistic worst case is that iOS closes the app, the phone gets warm, or storage fills up; there is no risk to your data. If the app is closed, the next launch explains what happened.

## Benchmarks

*Modelos locales → Benchmark en este iPhone* runs protocol v1:

- greedy decoding, 2K context;
- four fixed tasks: short answer, JSON object, long prefill, sustained generation.

It records:

- load time, prefill and generation tokens per second;
- peak `phys_footprint` and thermal state;
- whether each output passed its check.

The report contains no prompt or answer text.

- **KILLED results:** if iOS terminates the app mid-run, the next launch offers a KILLED result, including where it stopped.
- **Publishing:** use the *GUS benchmark result* issue form. A maintainer adds the `benchmark-approved` label. `benchmark-intake.yml` then validates the JSON with `scripts/benchmarks/validate.py`, which checks the catalog hash and the llama.cpp commit and applies strict ranges. It stores a sanitized copy under `benchmarks/`, regenerates [BENCHMARKS.md](BENCHMARKS.md), and opens a PR.

## Crash reports

iOS stops an app that exceeds its memory limit with SIGKILL, which no code can catch. The flight recorder therefore writes ahead:

- **Session marker (`session.json`):** the current phase (model load, generation, benchmark), the model, whether the app is in the foreground, and peak memory.
- **Breadcrumbs (`breadcrumbs.jsonl`):** timestamped events with footprint and available memory. They record sizes and token counts only, never message text.
- **Signal trap:** an async-signal-safe handler records SIGABRT (a llama.cpp assert), SIGSEGV and similar signals, then lets the system crash report proceed.
- **MetricKit:** Apple's crash diagnostics (call stacks) and daily exit-reason counters. These confirm memory-limit terminations.

On the next launch, a marker that is still open while the app was in a risky foreground phase becomes a report such as:

> La app terminó durante la carga del modelo · qwen3-4b-q4km. Probablemente iOS la cerró por exceder su límite de memoria (jetsam). Última medición: 2.9 GB en uso, 40 MB disponibles.

Reports are listed under *Informes de fallos*. Each one can be exported as JSON or filed with the *Crash report* issue form.
