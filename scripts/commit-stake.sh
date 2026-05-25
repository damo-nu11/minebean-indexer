#!/usr/bin/env bash
# commit-stake.sh
#
# Takes the snapshot JSON emitted by fetch-stake.sh and pushes it to the
# minebean-stake Gitlawb repo. One file per cron tick, idempotent on the
# filename (snapshot_at + block_number).
#
# Required env:
#   STAKE_JSON_PATH        path to the snapshot file
#   GITLAWB_STAKE_REPO     gitlawb:// URL of minebean-stake
#   GITLAWB_DID            the DID stamped into commit author
# Optional env:
#   DRY_RUN                if "true", logs intended action without pushing

set -euo pipefail

: "${STAKE_JSON_PATH:?STAKE_JSON_PATH is required}"
: "${GITLAWB_STAKE_REPO:?GITLAWB_STAKE_REPO is required}"
: "${GITLAWB_DID:?GITLAWB_DID is required}"

if [ ! -f "$STAKE_JSON_PATH" ]; then
    echo "ERROR: stake file not found at $STAKE_JSON_PATH" >&2
    exit 1
fi

SNAPSHOT_AT=$(jq -r '.snapshot_at' "$STAKE_JSON_PATH")
BLOCK_NUMBER=$(jq -r '.block_number' "$STAKE_JSON_PATH")

if [ -z "$SNAPSHOT_AT" ] || [ "$SNAPSHOT_AT" = "null" ]; then
    echo "ERROR: could not parse snapshot_at from $STAKE_JSON_PATH" >&2
    exit 1
fi
if [ -z "$BLOCK_NUMBER" ] || [ "$BLOCK_NUMBER" = "null" ]; then
    echo "ERROR: could not parse block_number from $STAKE_JSON_PATH" >&2
    exit 1
fi

YEAR="${SNAPSHOT_AT:0:4}"
MONTH="${SNAPSHOT_AT:5:2}"
DAY="${SNAPSHOT_AT:8:2}"
FN_TS="$(echo "$SNAPSHOT_AT" | tr -d ':')"
TARGET_PATH="snapshots/${YEAR}/${MONTH}/${DAY}/snapshot-${FN_TS}-${BLOCK_NUMBER}.json"

echo "Target path: $TARGET_PATH"

if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "DRY_RUN: would push $STAKE_JSON_PATH to $GITLAWB_STAKE_REPO at $TARGET_PATH"
    exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Cloning $GITLAWB_STAKE_REPO ..."
git clone "$GITLAWB_STAKE_REPO" "$WORK_DIR/minebean-stake"
cd "$WORK_DIR/minebean-stake"

if [ -f "$TARGET_PATH" ]; then
    echo "SKIP: $TARGET_PATH already exists in repo"
    exit 0
fi

git config user.name "$GITLAWB_DID"
git config user.email "${GITLAWB_DID}@gitlawb"

mkdir -p "$(dirname "$TARGET_PATH")"
cp "$STAKE_JSON_PATH" "$TARGET_PATH"

git add "$TARGET_PATH"
git commit -m "stake snapshot at ${SNAPSHOT_AT} (block ${BLOCK_NUMBER})"

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
