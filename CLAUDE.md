# Working agreement — local-model offload

This repo uses a 3-role local-model workflow: **I (Claude) plan and review;
the local model implements** via aider → ollama. Bulk codegen runs free on
the homelab GPU (RTX 5070 Ti, Ollama LoadBalancer via Cilium LB-IPAM).

Cluster infra (Ollama deployment, GPU node, networking) is GitOps-managed in
the **homelab repo** (CDK8s → ArgoCD) — not here. This repo owns only the
role Modelfiles, the sync script, and the offload workflow.

## Roles

| Role | Model | Purpose |
|---|---|---|
| **executor** | `ollama/executor` | Implements steps via aider |

Built `FROM hf.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:UD-Q3_K_XL`,
`num_ctx 28672`. Planning and review are mine — no local planner or validator.

Sync: `./ollama/sync-models.sh`

The cluster pulls the base weights declaratively; `executor` itself is an
`ollama create` on top of them, so it is this repo's job and must be re-run
against any freshly provisioned model volume.

**16GB VRAM rule:** weights ≤14GB so model + KV cache stay 100% VRAM-resident.
A spill crosses the eGPU dock's OCuLink x4 link and costs throughput (measured
on GLM: 107.8 → 25.8 tok/s). Verify with `/api/ps` — `size_vram` must equal
`size`. See README for the sizing table.

**Picking a replacement model:** SWE-bench rank does not predict aider behavior
at Q3. GLM-4.7-Flash outscores Qwen3-Coder by ~37 points and still lost the
bake-off. Always run a real repo-scale task and check the result executes, not
just that it parses.

## Commands

| Command | What it does |
|---|---|
| `/offload <task or plan.md> [-- file1 file2]` | Delegate to local model, show diff, review |

## Workflow

1. **Plan** — Claude produces a short plan
2. **Delegate** — `/offload` or `aider --yes --message "<task>"`
3. **Review** — Claude inspects `git diff`
4. **Iterate** — re-run aider with targeted `--message`
5. **No commit** — unless explicitly asked

Trivial one-line edits: Claude does directly. Everything else: delegate.

## Prereqs

```bash
uv tool install aider-chat
cp .env.example .env
source .env
./ollama/sync-models.sh
curl -sf "${OLLAMA_API_BASE}/api/tags" | python3 -m json.tool
```

| Connection | Command |
|---|---|
| LAN direct (Cilium LB) | `export OLLAMA_API_BASE=http://<lb-ip>:11434` |
| Port-forward Ollama | `kubectl -n ollama port-forward svc/ollama 11434:11434` |

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ollama NOT reachable` | `kubectl -n ollama port-forward svc/ollama 11434:11434` |
| `model not found` | `./ollama/sync-models.sh` |
| `/api/tags` lists only base models, `executor` gone | The model dir lost its PVC. Check `kubectl -n ollama get pvc` binds; the otwld chart's key is `persistentVolume`, and a wrong key silently degrades it to `emptyDir`. Re-create with `./ollama/sync-models.sh --force` |
| aider wrong model | Unset `AIDER_MODEL`; check `.aider.conf.yml` |
| Decode drops to ~25 tok/s | Model spilled to host RAM. Check `/api/ps`; lower `num_ctx` |
| `</think>` in filenames or edits | Never prefill `<think></think>` in a Modelfile TEMPLATE — Ollama only strips it when the model reports the `thinking` capability; check `/api/show` |
| Edits ignore chat history | Community GGUF shipped a single-turn template. Grep the `/api/show` template for `range.*\.Messages` before adopting a new base — Qwen's real loop is `{{- range $i, $_ := .Messages }}`, so an exact-string search for `{{ range .Messages }}` false-negatives a working model. A single-turn template has no `.Messages` at all and reports `capabilities: [completion]` only |
| GPU missing after Talos boot | Blackwell needs `nvidia-open-gpu-kernel-modules` (proprietary branch does not support RTX 50xx) + `nvidia-container-toolkit`, version-matched, via Image Factory schematic |
| Other PCI passthrough broke | Attaching the eGPU dock can renumber IOMMU groups. OCuLink is not hot-plug safe — power the dock before host boot |
