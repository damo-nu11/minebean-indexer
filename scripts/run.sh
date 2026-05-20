#!/usr/bin/env bash
# run.sh
#
# Orchestrator. Calls fetch-window to build a window JSON, then commit-window
# to push it to Gitlawb. Intended to be invoked from a cron / workflow.
#
# Required env (forwarded to children):
#   BASE_RPC_URL
#   GITLAWB_PSEUDONYM_SALT
#   GITLAWB_REPO_URL
#   GITLAWB_DID
# Optional env:
#   ROUNDS_PER_WINDOW   default 5
#   DRY_RUN             default false

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_PATH="${OUTPUT_PATH:-/tmp/minebean-indexer-window.json}"

echo "=== minebean-indexer run started at $(date -u +%FT%TZ) ==="

# Step 1: fetch the latest window
echo "--- Fetching window ---"
OUTPUT_PATH="$OUTPUT_PATH" bash "$SCRIPT_DIR/fetch-window.sh"

if [ ! -s "$OUTPUT_PATH" ]; then
    echo "ERROR: fetch-window.sh produced no output at $OUTPUT_PATH" >&2
    exit 1
fi

echo "--- Committing window ---"
WINDOW_JSON_PATH="$OUTPUT_PATH" bash "$SCRIPT_DIR/commit-window.sh"

echo "=== Run complete ==="
