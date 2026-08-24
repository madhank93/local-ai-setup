# local-ai-setup

Cut Claude (cloud) token spend by offloading bulk implementation to a local
model on the homelab GPU. **Claude Code plans + reviews (cloud); aider + a
local model implement (homelab GPU).**

Cluster infrastructure (Ollama deployment, GPU passthrough, LoadBalancer,
GitOps) lives in the [homelab repo](https://homelab.madhan.app/) — this repo
owns only the offload workflow: role Modelfiles, the sync script, and the
`/offload` command.

```
Laptop                              Homelab GPU (RTX 5070 Ti, 16GB)
  Claude Code ──HTTPS──► Anthropic     Ollama
    │  plan.md / git diff               └── executor
  aider ────────HTTP/LAN───────────►         (Qwen3-Coder-30B-A3B Q3)
```

## Architecture

Two brains, split by what each is good at. Claude is expensive per token but
reasons well; the local model is free but drifts. So Claude spends tokens on
*deciding* and the GPU spends time on *typing*.

```
  ┌─ laptop (macOS) ──────────────────────┐   ┌─ homelab ─────────────────────┐
  │                                       │   │                               │
  │  Claude Code                          │   │  Proxmox host                 │
  │   ├─ ~/.claude/OFFLOAD.md  (rules)    │   │   └─ VFIO passthrough         │
  │   └─ /offload  (command)              │   │       ↓                       │
  │        │ shells out                   │   │  Talos VM (k8s worker)        │
  │        ↓                              │   │   ├─ nvidia-open-gpu-kmods    │
  │  aider                                │   │   ├─ nvidia-container-toolkit │
  │   ├─ ~/.aider.conf.yml (model, fmt)   │   │   └─ ollama pod               │
  │   ├─ ~/.env (OLLAMA_API_BASE) ────────┼───┼──→  :11434  (Cilium LB-IPAM)  │
  │   ├─ repo-map (tree-sitter)           │   │       └─ executor model       │
  │   └─ writes SEARCH/REPLACE to disk    │   │            ↕ PCIe 4.0 x4      │
  │        │                              │   │       AOOSTAR AG02 (OCuLink)  │
  │        ↓                              │   │            ↕                  │
  │  git diff ──── back to Claude ────────┼───┤       RTX 5070 Ti 16GB GDDR7  │
  └───────────────────────────────────────┘   └───────────────────────────────┘
```

### What each piece does

| Component | Owns | Lives in |
|---|---|---|
| **Claude Code** | Plans, reviews diffs, decides when a task is too small to delegate | cloud |
| `~/.claude/OFFLOAD.md` | Global working agreement — the delegate/don't-delegate rule | laptop |
| `/offload` | Probes ollama, runs aider, prints the diff, reviews it, never commits | laptop |
| **aider** | Builds the prompt (repo-map + files), applies edit blocks, retries on malformed output | laptop |
| `~/.aider.conf.yml` | Which model, which edit format, no auto-commits | laptop |
| `~/.env` | `OLLAMA_API_BASE` — auto-loaded by aider in every repo | laptop |
| **Ollama** | Serves `executor`, manages VRAM, applies the Modelfile's params + template | Talos pod |
| `executor.Modelfile` | Base build, measured `num_ctx`, sampling, system prompt | **this repo** |
| `sync-models.sh` | Pulls the base and rebuilds `executor` on any host | **this repo** |
| **Cilium LB-IPAM** | Gives the ollama Service a LAN IP so the laptop reaches it without port-forward | homelab repo |
| **Talos + VFIO** | Passes the physical GPU into the k8s node | homelab repo |

### The request path

1. You type `/offload "<task>"`. Claude sources `~/.env`, probes `/api/tags`, stops if unreachable.
2. Claude shells out to `aider --yes --message "<task>"`. **This is the token boundary** — Claude does not see the edit loop.
3. aider assembles context: tree-sitter repo-map (≤1024 tokens) + any named files + chat history, and POSTs to `$OLLAMA_API_BASE`.
4. Ollama loads `executor` (~13.8GB into VRAM, one time), applies the Modelfile's template and params, decodes at ~37 tok/s.
5. aider parses the SEARCH/REPLACE blocks and writes to disk. Malformed output → it re-prompts, up to 3 reflections.
6. Claude reads `git diff`, reviews, and either accepts, re-prompts aider with a correction, or fixes it directly.
7. Nothing is committed. That is your call.

### Why the pieces are where they are

- **Endpoint in `~/.env`, not a shell rc** — aider auto-loads `~/.env` in every repo, and the file is not git-tracked, so the LAN IP never reaches GitHub.
- **Model definition in this repo, cluster config in the homelab repo** — the Modelfile changes when a better model ships; the GPU plumbing changes when hardware changes. Different cadences.
- **`num_ctx` in the Modelfile, not passed per-call** — it is a hardware fact (the 16GB residency ceiling), not a per-task preference.
- **`auto-commits: false` everywhere** — the local model is a Q3 quant. Every diff gets human or Claude review before it becomes history.

## The model

| Role | Model | Purpose |
|---|---|---|
| **executor** | `ollama/executor` | Implements steps via aider, minimal diffs |

Built `FROM hf.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:UD-Q3_K_XL` — see
`ollama/models/executor.Modelfile`. Planning and review stay with Claude, so
there is no local planner or validator model.

Chosen by bake-off, not by benchmark score. All three candidates were given the
same real task (add a `--list` flag to `sync-models.sh`) through aider:

| Candidate | Result |
|---|---|
| **Qwen3-Coder-30B-A3B Q3** | correct on both code paths, 73s |
| qwen2.5-coder:14b Q4 (previous default) | passed `bash -n`, but left `LIST_MODE` uninitialized — the default path dies with `unbound variable` under `set -u` |
| GLM-4.7-Flash Q3 (higher SWE-bench: 59.2 vs ~22) | unbalanced `if`, duplicated blocks, hallucinated a `/echo?msg=ok` health-check URL, exhausted aider's reflections |

GLM also ships a single-turn chat template in its community GGUF (no `.Messages`
loop, `capabilities: [completion]` only), which flattens aider's multi-turn
context. Qwen3-Coder's GGUF ships a correct multi-turn template.

## Hardware envelope

16GB VRAM is the binding constraint. Weights must stay under ~14GB so the model
plus its KV cache is **100% VRAM-resident** — anything that spills crosses the
AOOSTAR AG02 dock's OCuLink link (PCIe 4.0 x4, ~8 GB/s) instead of GDDR7
(896 GB/s). Measured on this card:

Every row below with an f16 KV cache was measured before
`OLLAMA_FLASH_ATTENTION` and `OLLAMA_KV_CACHE_TYPE` were actually set on the
cluster — this file required them, the deployment never had them, and the KV
cache silently stayed f16 at ~90KB/token. Setting them halves that to 45KB and
doubles the context that fits.

| Config | KV | Footprint | On GPU | Decode |
|---|---|---|---|---|
| Qwen3-Coder Q3, `num_ctx` 32768 | f16 | 17.38GB | 89.2% | 30.9 tok/s |
| Qwen3-Coder Q3, `num_ctx` 16384 | f16 | 15.55GB | 97.9% | 6.4 tok/s |
| Qwen3-Coder Q3, `num_ctx` 14336 | f16 | 15.14GB | 100% | 105-113 tok/s |
| Qwen3-Coder Q3, `num_ctx` 14336 | q8_0 | 14.48GB | 100% | 122-133 tok/s |
| Qwen3-Coder Q3, **`num_ctx` 28672** | **q8_0** | 15.24GB | **100%** | **109-129 tok/s** |
| GLM-4.7-Flash Q3, `num_ctx` 32768 | f16 | 17.54GB | 89.3% | 25.8 tok/s |
| GLM-4.7-Flash Q3, `num_ctx` 16384 | f16 | 15.60GB | 100% | 107.8 tok/s |

The KV cache is the only part of the footprint that grows with context; weights
and compute graph are a fixed 13.82GB. At q8_0 that leaves room for 28672
tokens inside the same 15.14GB that was already proven resident — verified with
a 20,973-token prompt at 4263 tok/s prefill, `size_vram == size` throughout.

The cliff is not gradual. Qwen3-Coder at f16/16384 misses full residency by
0.32GB and loses 94% of its decode rate; 2K less context buys all of it back.
Treat `size_vram == size` in `/api/ps` as pass/fail, not as a gauge.

Take the reading **warm**. The first request after a load charges CUDA init to
decode and reports ~6 tok/s — identical to the spill signature, and wrong.

What does *not* fit: `devstral-small-2:24b` (15GB), `qwen3.6:27b` (17GB),
`qwen3-coder:30b-a3b` q4 (19GB), `glm-4.7-flash` official q4 tag (19GB),
`qwen3.6:35b-a3b` (24GB). Before raising `num_ctx` or swapping the base model,
check `GET /api/ps` — `size_vram` must equal `size`.

## Setup

Global (works in every repo on this machine — already installed):

| File | Purpose |
|---|---|
| `~/.env` | `OLLAMA_API_BASE` — aider auto-loads it anywhere |
| `~/.aider.conf.yml` | `model: ollama/executor`, diff edits, no auto-commits |
| `~/.claude/commands/offload.md` | `/offload` in any project |
| `~/.claude/OFFLOAD.md` | working agreement, included from `~/.claude/CLAUDE.md` |

A repo-local `.aider.conf.yml` or `.env` overrides the global one. This repo keeps
both so it stays self-contained.

First-time / new-machine bootstrap:

```bash
uv tool install aider-chat        # aider on PATH
cp .env.example .env              # set OLLAMA_API_BASE
source .env
./ollama/sync-models.sh           # pull base + build the executor model
```

First sync downloads 13.8GB. Ollama must have `OLLAMA_FLASH_ATTENTION=1` and
`OLLAMA_KV_CACHE_TYPE=q8_0` set (homelab repo) — without flash attention the KV
cache type is silently ignored and falls back to f16, which halves the context
that fits inside the VRAM budget.

`sync-models.sh` resolves the endpoint from `OLLAMA_HOST`, then
`OLLAMA_API_BASE`, then `http://localhost:11434`. Supports `--dry-run` and
`--force`.

| Connection | Command |
|---|---|
| LAN direct (Cilium LB) | `export OLLAMA_API_BASE=http://<lb-ip>:11434` |
| Port-forward | `kubectl -n ollama port-forward svc/ollama 11434:11434` |

## Usage

```bash
# Via Claude Code:
/offload "add retry logic to sync-models.sh"

# Direct:
aider --yes --message "<task>"
```

Loop: Claude plans → aider implements → Claude reviews `git diff` → iterate.
Claude only ever sees the plan and the diffs — never the token-heavy edit loop.

### What the executor is good and bad at

Measured, not guessed:

| Works | Struggles |
|---|---|
| Adding functions, flags, boilerplate to existing files | Argument-parsing logic with positional edge cases |
| Following an existing file's style | Staying in scope (adds unrequested docstrings) |
| Producing valid SEARCH/REPLACE blocks | Code that parses but does not run |

Two observed failures shipped code that passed `bash -n` and then died at runtime
(`unbound variable` under `set -u`; a flag that silently did nothing). **Review
behavior, not syntax.** If two prompts in a row miss, write it yourself.

See `CLAUDE.md` for the full working agreement.
