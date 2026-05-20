#!/usr/bin/env bash
# commit-window.sh
#
# Takes a window JSON file and pushes it to the minebean-rounds Gitlawb repo.
# Skips the push if a file with the same path already exists (idempotent).
#
# Required env:
#   WINDOW_JSON_PATH   path to the window file to commit
#   GITLAWB_REPO_URL   gitlawb:// URL to push to
#   GITLAWB_DID        the DID that will appear in commit author
# Optional env:
#   DRY_RUN            if "true", logs intended action without pushing

set -euo pipefail

: "${WINDOW_JSON_PATH:?WINDOW_JSON_PATH is required}"
: "${GITLAWB_REPO_URL:?GITLAWB_REPO_URL is required}"
: "${GITLAWB_DID:?GITLAWB_DID is required}"

if [ ! -f "$WINDOW_JSON_PATH" ]; then
    echo "ERROR: window file not found at $WINDOW_JSON_PATH" >&2
    exit 1
fi

# Read window_start from the JSON to compute target path
WINDOW_START=$(grep -m1 '"window_start"' "$WINDOW_JSON_PATH" | sed -E 's/.*"window_start"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
if [ -z "$WINDOW_START" ]; then
    echo "ERROR: could not parse window_start from $WINDOW_JSON_PATH" >&2
    exit 1
fi

# Compose target path: windows/YYYY/MM/DD/window-<ts>.json
# WINDOW_START is like "2026-05-20T09:00:00Z"
YEAR="${WINDOW_START:0:4}"
MONTH="${WINDOW_START:5:2}"
DAY="${WINDOW_START:8:2}"
# Filename uses compact ISO with no colons
FN_TS="$(echo "$WINDOW_START" | tr -d ':')"
TARGET_PATH="windows/${YEAR}/${MONTH}/${DAY}/window-${FN_TS}.json"

echo "Target path: $TARGET_PATH"

if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "DRY_RUN: would push $WINDOW_JSON_PATH to $GITLAWB_REPO_URL at $TARGET_PATH"
    exit 0
fi

# Clone the gitlawb repo into a working dir
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Cloning $GITLAWB_REPO_URL ..."
git clone "$GITLAWB_REPO_URL" "$WORK_DIR/minebean-rounds"
cd "$WORK_DIR/minebean-rounds"

# Idempotency check: skip if target already exists
if [ -f "$TARGET_PATH" ]; then
    echo "SKIP: $TARGET_PATH already exists in repo"
    exit 0
fi

# Configure git identity to use the DID
git config user.name "$GITLAWB_DID"
git config user.email "${GITLAWB_DID}@gitlawb"

# Write the file
mkdir -p "$(dirname "$TARGET_PATH")"
cp "$WINDOW_JSON_PATH" "$TARGET_PATH"

# Commit and push
git add "$TARGET_PATH"
git commit -m "window ${WINDOW_START}: 5 rounds"
git push origin main

echo "Pushed $TARGET_PATH"
