#!/usr/bin/env bash
# Push all Modelfiles to a running Ollama instance.
# Usage: OLLAMA_HOST=http://ollama.homelab.madhan.app ./sync-models.sh
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
