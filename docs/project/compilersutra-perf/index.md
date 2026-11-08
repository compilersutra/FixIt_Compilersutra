---
title: "CompilerSutraPerf"
sidebar_label: "Overview"
description: "csperf — compile, run, profile, and compare C/C++ and GPU workloads with structured JSON artifacts and honest evidence labels."
displayed_sidebar: csperfSidebar
keywords:
  - compilersutra-perf
  - csperf
  - performance tooling
  - compiler benchmarking
---

# CompilerSutraPerf

**CompilerSutraPerf** (`csperf`) is a Linux-first CLI for **compiler and GPU performance experiments**. You point it at a C/C++ source or a GPU kernel, it compiles and runs through the real toolchain (`clang` / `g++` / `hipcc` / OpenCL / Vulkan), optionally collects hardware counters, and writes **structured JSON** (plus CSV / HTML / PDF) you can diff and cite.

Package: [PyPI — `compilersutra-perf`](https://pypi.org/project/compilersutra-perf/) · Current line: **[0.3.0](/docs/project/compilersutra-perf/releases/0.3.0/)** · Status: **Alpha** (not a production CI gate yet).

It does **not** replace Clang, `perf`, HIP, or Vulkan — it **orchestrates** them and keeps measurement honesty (hardware vs emulated vs static) in the artifact.

## Who this is for

- Compiler / systems engineers comparing flags, experiments, or backends on the same workload
- Researchers who need reproducible run artifacts (not screenshots)
- Teams that want one CLI across CPU + HIP/OpenCL/Vulkan bring-up

If you only need a one-off `perf stat`, use `perf`. If you need a fair, repeatable loop with provenance and diffs, use `csperf`.

## Install and first win

Requires **Python 3.11+**. Linux is primary; Windows → WSL2.

```bash
pip install 'compilersutra-perf==0.3.0'
# optional reports / dashboard:
pip install 'compilersutra-perf[excel,pdf,visualize]'

csperf doctor
csperf quickstart --output-dir results/quickstart
```

`doctor` checks compilers, `perf`, and GPU tools (exits **1** if a required tool is missing).  
`quickstart` = doctor + bundled CPU example + profile summary + HTML report when available.

Missing system packages:

```bash
csperf doctor --install        # required tools
csperf doctor --install --all  # also optional GPU / profiling tools
```

Full walkthrough: [Getting started](/docs/project/compilersutra-perf/getting-started/) · [Tutorial](/docs/project/compilersutra-perf/tutorial/).

## What a typical run looks like

```bash
csperf list-backends
csperf list-devices --backend cpu

csperf run --input path/to/kernel.cpp --backend cpu \
  --warmup-runs 1 --repeat-runs 3 \
  --output results/cpu.json

csperf profile results/cpu.json
csperf visualize results/cpu.json --output results/cpu.html
```

Opt-level sweep with a comparison report:

```bash
csperf run --input path/to/kernel.cpp \
  --diff-optimize --no-perf --report-format both
# → results/optimize/*.json + optimize_report.html
```

Each successful `run` writes a versioned result artifact (`schema_version` 2 in 0.3.x) with timings, optional counters, hardware metadata, and provenance.

## Backends (0.3.0)

| Backend | Maturity | What you get |
| --- | --- | --- |
| **CPU** | Stable (Linux) | Compile + native run, warmup/repeat, optional `perf` / PAPI, affinity |
| **HIP** | Experimental | `hipcc` + ROCm devices, rocprof\* when available |
| **OpenCL** | Experimental | Kernel launch, device selection, warmup/repeat |
| **Vulkan** | Experimental | Prefers [CompilerSutraRun](https://github.com/compilersutra/CompilerSutraRun) (`csrun`) execute; else SPIR-V validate (`partial`) |
| **`gpu` alias** | Experimental | Routes by input (`.hip` → HIP, `.cl` → OpenCL, shaders → Vulkan) |
| **CUDA / Metal** | Planned | Listed, not executable |
| **macOS CPU** | Experimental | Runs; profiling via `powermetrics` (needs passwordless `sudo`) |

## CLI map

| Command | Role |
| --- | --- |
| `csperf doctor` | Toolchain health check |
| `csperf quickstart` | First smoke: doctor + example + report |
| `csperf run` | Compile, execute, optional profile / energy |
| `csperf profile` | Summarize a saved JSON |
| `csperf diff` | Compare two result files |
| `csperf visualize` / `dashboard` | HTML / PDF / Streamlit |
| `csperf list-backends` / `list-devices` | Discovery |
| `csperf list-energy-backends` | RAPL / GPU power collectors |
| `csperf list-experiments` | Built-in + plugin compile experiments |
| `csperf list-toolchains` | Compiler / LLVM discovery |
| `csperf export-schema` | JSON Schema for result artifacts |

Recipes and flags: [Usage](/docs/project/compilersutra-perf/usage/).

## Evidence honesty

Result JSON carries `measurement_type` so you do not mix unlike numbers:

| Label | Meaning |
| --- | --- |
| `hardware` | Timed / counted on real silicon |
| `emulated` | QEMU (or similar) wall time — **not** guest PMU |
| `static` / `model` | Analysis or model estimates (roadmap / plugins) |
| `unavailable` / `planned` | Missing or not yet run |

Read [Methodology](/docs/project/compilersutra-perf/methodology/) before publishing numbers. Research framing: [Observatory](/docs/project/compilersutra-perf/observatory/).

## Extensibility (0.3)

Out-of-tree plugins register via Python entry points (`csperf.experiments`, `csperf.backends`, visualizers, GPU profilers, toolchains). Schema v2 + `export-schema` stabilize the artifact surface. See the in-tree [EXTENDING](https://github.com/compilersutra/CompilerSutraPerfTool/blob/main/docs/EXTENDING.md) guide and [0.3.0 release notes](/docs/project/compilersutra-perf/releases/0.3.0/).

## Documentation

| Page | Use when you need… |
| --- | --- |
| [Getting started](/docs/project/compilersutra-perf/getting-started/) | Install → first JSON today |
| [Tutorial](/docs/project/compilersutra-perf/tutorial/) | Longer, perfwiki-style walkthrough |
| [Usage](/docs/project/compilersutra-perf/usage/) | Flags, manifests, recipes |
| [Methodology](/docs/project/compilersutra-perf/methodology/) | How to trust (or not trust) counters |
| [Architecture](/docs/project/compilersutra-perf/architecture/) | Layers, pipeline phases, runners |
| [Energy & reports](/docs/project/compilersutra-perf/energy-and-reports/) | RAPL / HTML / PDF |
| [Observatory](/docs/project/compilersutra-perf/observatory/) | Research goal and roadmap |
| [Troubleshooting](/docs/project/compilersutra-perf/troubleshooting/) | Doctor, perf, energy, GPU failures |
| [Releases](/docs/project/compilersutra-perf/releases/) | Version pins and changelogs |

## Releases

| Release | Status | Notes |
| --- | --- | --- |
| **[0.3.0](/docs/project/compilersutra-perf/releases/0.3.0/)** | Current · Alpha | Plugins, schema v2, csrun Vulkan, `emulated` evidence |
| [0.2.0](/docs/project/compilersutra-perf/releases/0.2.0/) | Previous | Quickstart, energy, `--diff-optimize`, reports |
| [0.1.x](/docs/project/compilersutra-perf/releases/) | Older | Early MVP / maintenance |

Prefer the current pin unless you are reproducing an older experiment:

```bash
pip install 'compilersutra-perf==0.3.0'
```

## Limits (read before citing)

- **Alpha** — methodology and GPU coverage are still evolving; not a locked CI regression suite.
- CPU is the strongest path on Linux with `perf` configured.
- Treat unmatched CPU vs GPU runs as **not** equivalent workloads.
- Emulated (QEMU) timings are never hardware PMU claims.
- CUDA and Metal are not implemented.

Part of the [Projects catalogue](/docs/project/).
