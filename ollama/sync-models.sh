#!/usr/bin/env bash
# Push all Modelfiles to a running Ollama instance.
#
# Usage:
#   ./ollama/sync-models.sh
#   OLLAMA_HOST=http://192.168.x.x:11434 ./ollama/sync-models.sh
#   ./ollama/sync-models.sh --dry-run
#   ./ollama/sync-models.sh --force
#
# Connection priority:
#   1. OLLAMA_HOST       (Cilium LB-IPAM LAN IP)
#   2. OLLAMA_API_BASE   (aider format — strips /v1 suffix)
#   3. http://localhost:11434
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/models"
DRY_RUN=false; FORCE=false
# Must match FROM in models/executor.Modelfile. UD-Q3_K_XL (13.8GB) is the largest build
# that stays 100% VRAM-resident on a 16GB card at num_ctx 28672 with a q8_0 KV
# cache — see README.
BASE_MODEL="hf.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:UD-Q3_K_XL"

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --force)   FORCE=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if [[ -n "${OLLAMA_HOST:-}" ]]; then
  HOST="$OLLAMA_HOST"
elif [[ -n "${OLLAMA_API_BASE:-}" ]]; then
  HOST="${OLLAMA_API_BASE%/v1}"
else
  HOST="http://localhost:11434"
fi
export OLLAMA_HOST="$HOST"
echo "-> target: $OLLAMA_HOST"

if ! curl -sf "${HOST}/api/tags" >/dev/null; then
  echo "FAIL ollama not reachable at $HOST" >&2
  echo "  kubectl -n ollama port-forward svc/ollama 11434:11434" >&2
  exit 1
fi
echo "ok ollama reachable"

if [[ "$DRY_RUN" == true ]]; then
  echo "[dry-run] would pull: $BASE_MODEL"
else
  echo "-> pulling base: $BASE_MODEL"
  ollama pull "$BASE_MODEL"
fi

mapfile -t modelfiles < <(find "$MODELS_DIR" -name "*.Modelfile" | sort)
[[ ${#modelfiles[@]} -eq 0 ]] && { echo "FAIL no Modelfiles in $MODELS_DIR" >&2; exit 1; }
echo "-> ${#modelfiles[@]} model(s) to sync"

for modelfile in "${modelfiles[@]}"; do
  name=$(basename "$modelfile" .Modelfile)
  if [[ "$FORCE" == false ]] && ollama list 2>/dev/null | grep -q "^${name}:"; then
    echo "  skip $name (--force to recreate)"
    continue
  fi
  if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] create: $name"
  else
    echo "  -> creating: $name"
    ollama create "$name" -f "$modelfile"
  fi
done

[[ "$DRY_RUN" == true ]] && echo "ok dry-run complete" || { echo "ok all models synced"; ollama list; }
