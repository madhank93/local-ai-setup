---
description: Delegate implementation to the local model (aider → ollama). Planning/review stay with Claude; bulk codegen runs free on the homelab GPU.
argument-hint: <task, or path to plan.md> [-- file paths...]
allowed-tools: Bash(aider:*), Bash(git diff:*), Bash(git status:*), Bash(curl:*), Bash(test:*), Bash(. ./.env:*)
---

Delegate the following implementation to the local model, then show me the diff to review.

**Task:** $ARGUMENTS

Do this:

1. **Load endpoint + check reachability.** Source `.env` if present, then probe ollama:
   ```bash
   set -a; [ -f .env ] && . ./.env; set +a
   curl -sf "${OLLAMA_API_BASE:-http://localhost:11434}/api/tags" >/dev/null \
     && echo "ollama reachable" \
     || echo "ollama NOT reachable — set OLLAMA_API_BASE or start: kubectl -n ollama port-forward svc/ollama 11434:11434"
   ```
   If unreachable, stop and tell me how to fix it.

2. **Run aider non-interactively** (uses repo `.aider.conf.yml`: `ollama/qwen2.5-coder:14b`, diff edits, no auto-commit). If I listed files after `--`, pass them; otherwise let aider use its repo-map:
   ```bash
   aider --yes --message "$ARGUMENTS"
   ```

3. **Show the result:** `git diff --stat` then the full `git diff`.

4. **Review** the diff for correctness, obvious bugs, and whether it satisfies the task. Note anything to fix — and if needed, re-run aider with a follow-up `--message` to correct it.

5. **Do not commit.** Leave the working tree for me to inspect and commit.
