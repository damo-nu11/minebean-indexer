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

# Commit and push with retry on non-fast-forward (handles gitlawb gateway lag
# and overlapping cron runs that would otherwise race on main).
git add "$TARGET_PATH"
git commit -m "window ${WINDOW_START}: 5 rounds"

PUSH_MAX_ATTEMPTS=3
for attempt in $(seq 1 "$PUSH_MAX_ATTEMPTS"); do
    if git push origin main; then
        echo "Pushed $TARGET_PATH (attempt $attempt)"
        exit 0
    fi
    if [ "$attempt" -ge "$PUSH_MAX_ATTEMPTS" ]; then
        echo "ERROR: push failed after $PUSH_MAX_ATTEMPTS attempts" >&2
        exit 1
    fi
    echo "Push attempt $attempt failed, fetching and rebasing..."
    git fetch origin main
    if ! git rebase origin/main; then
        echo "ERROR: rebase conflict against origin/main, aborting" >&2
        git rebase --abort || true
        exit 1
    fi
    sleep $((attempt * 2))
done
