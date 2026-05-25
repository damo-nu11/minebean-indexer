#!/usr/bin/env bash
# commit-nostradamus.sh
#
# Takes a Nostradamus decision JSON file and pushes it to the
# minebean-nostradamus Gitlawb repo. Skips if a file already exists for the
# same round_id (decision files are immutable, one per round).
#
# Required env:
#   DECISION_JSON_PATH         path to the decision file
#   GITLAWB_NOSTRADAMUS_REPO   gitlawb:// URL to push to
#   GITLAWB_DID                the DID stamped into commit author
# Optional env:
#   DRY_RUN                    if "true", logs intended action without pushing

set -euo pipefail

: "${DECISION_JSON_PATH:?DECISION_JSON_PATH is required}"
: "${GITLAWB_NOSTRADAMUS_REPO:?GITLAWB_NOSTRADAMUS_REPO is required}"
: "${GITLAWB_DID:?GITLAWB_DID is required}"

if [ ! -f "$DECISION_JSON_PATH" ]; then
    echo "ERROR: decision file not found at $DECISION_JSON_PATH" >&2
    exit 1
fi

# Parse round_id and decided_at from the JSON to compute target path
ROUND_ID=$(jq -r '.decision.round_id' "$DECISION_JSON_PATH")
DECIDED_AT=$(jq -r '.decision.decided_at' "$DECISION_JSON_PATH")

if [ -z "$ROUND_ID" ] || [ "$ROUND_ID" = "null" ]; then
    echo "ERROR: could not parse decision.round_id from $DECISION_JSON_PATH" >&2
    exit 1
fi
if [ -z "$DECIDED_AT" ] || [ "$DECIDED_AT" = "null" ]; then
    echo "ERROR: could not parse decision.decided_at from $DECISION_JSON_PATH" >&2
    exit 1
fi

YEAR="${DECIDED_AT:0:4}"
MONTH="${DECIDED_AT:5:2}"
DAY="${DECIDED_AT:8:2}"
TARGET_PATH="decisions/${YEAR}/${MONTH}/${DAY}/decision-${ROUND_ID}.json"

echo "Target path: $TARGET_PATH"

if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "DRY_RUN: would push $DECISION_JSON_PATH to $GITLAWB_NOSTRADAMUS_REPO at $TARGET_PATH"
    exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Cloning $GITLAWB_NOSTRADAMUS_REPO ..."
git clone "$GITLAWB_NOSTRADAMUS_REPO" "$WORK_DIR/minebean-nostradamus"
cd "$WORK_DIR/minebean-nostradamus"

# Idempotency: append-only, one file per round_id. Skip if it exists.
if [ -f "$TARGET_PATH" ]; then
    echo "SKIP: $TARGET_PATH already exists in repo"
    exit 0
fi

git config user.name "$GITLAWB_DID"
git config user.email "${GITLAWB_DID}@gitlawb"

mkdir -p "$(dirname "$TARGET_PATH")"
cp "$DECISION_JSON_PATH" "$TARGET_PATH"

git add "$TARGET_PATH"
ACTION=$(jq -r '.decision.output.action' "$TARGET_PATH")
git commit -m "round ${ROUND_ID}: ${ACTION}"

# Push with retry+rebase, same pattern as commit-window.sh.
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
