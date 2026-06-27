#!/usr/bin/env bash
# Push all Modelfiles to a running Ollama instance.
# Usage: OLLAMA_HOST=http://<ollama-lan-ip>:11434 ./sync-models.sh   # LoadBalancer LAN IP (Cilium LB-IPAM); or http://localhost:11434 via `kubectl -n ollama port-forward svc/ollama 11434:11434`
set -euo pipefail

OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
MODELS_DIR="$(dirname "$0")/models"

for modelfile in "$MODELS_DIR"/*.Modelfile; do
  name=$(basename "$modelfile" .Modelfile)
  echo "→ creating model: $name"
  ollama create "$name" -f "$modelfile"
done

echo "✓ all models synced"
ollama list
