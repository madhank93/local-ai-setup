#!/usr/bin/env bash
# Push all Modelfiles to a running Ollama instance.
# Usage: OLLAMA_HOST=http://<ollama-lan-ip>:11434 ./sync-models.sh   # LoadBalancer LAN IP (Cilium LB-IPAM + L2 announcement); or http://localhost:11434 via `kubectl -n ai port-forward svc/ollama 11434:11434` (verify the Ollama namespace against your cluster)
set -euo pipefail

OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
MODELS_DIR="$(dirname "$0")/models"

# Role Modelfiles are FROM qwen2.5-coder:14b — ensure the base is present before
# `ollama create`, otherwise the build fails on a fresh node.
echo "→ pulling base model: qwen2.5-coder:14b"
ollama pull qwen2.5-coder:14b

for modelfile in "$MODELS_DIR"/*.Modelfile; do
  name=$(basename "$modelfile" .Modelfile)
  echo "→ creating model: $name"
  ollama create "$name" -f "$modelfile"
done

echo "✓ all models synced"
ollama list
