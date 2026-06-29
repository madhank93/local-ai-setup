# Working agreement — local-model offload

This repo uses a local-model offload workflow (see `README.md`): **I (Claude) plan
and review; the local model implements** via aider → ollama. One window, my
subscription pays only for planning + review, the bulk codegen runs free on the
homelab GPU.

## When you ask me to implement / build / write non-trivial code here

1. Produce a **short plan** first (what files, what changes).
2. **Delegate the implementation to the local model** instead of writing the bulk
   myself — run the `/offload` command, or directly:
   ```bash
   aider --yes --message "<the plan/task>"   # uses .aider.conf.yml → ollama/qwen2.5-coder:14b, no auto-commit
   ```
3. **Review** the resulting `git diff`, inspect/run tests, and iterate by re-running
   aider with follow-up instructions.
4. **Do not commit** unless you ask me to.

Keep my own token use to planning + review; let the local model generate the bulk.

**Prereqs:** `aider` on PATH (`uv tool install aider-chat`) and `OLLAMA_API_BASE`
set/reachable (from `.env` or the shell). Trivial one-line edits I can just make
directly — delegation is for non-trivial implementation.
