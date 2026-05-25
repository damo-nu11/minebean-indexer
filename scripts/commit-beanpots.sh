#!/usr/bin/env bash
# commit-beanpots.sh
#
# Takes the JSON array emitted by fetch-beanpots.sh and pushes any NEW
# beanpot hit files to the minebean-beanpots Gitlawb repo. Skips any file
# that already exists in the repo (append-only invariant from SCHEMA.md).
#
# Required env:
#   BEANPOTS_JSON_PATH       path to the hits array file
#   GITLAWB_BEANPOTS_REPO    gitlawb:// URL of minebean-beanpots
#   GITLAWB_DID              the DID stamped into commit author
# Optional env:
#   DRY_RUN                  if "true", logs intended action without pushing

set -euo pipefail

: "${BEANPOTS_JSON_PATH:?BEANPOTS_JSON_PATH is required}"
: "${GITLAWB_BEANPOTS_REPO:?GITLAWB_BEANPOTS_REPO is required}"
: "${GITLAWB_DID:?GITLAWB_DID is required}"

if [ ! -f "$BEANPOTS_JSON_PATH" ]; then
    echo "ERROR: beanpots file not found at $BEANPOTS_JSON_PATH" >&2
    exit 1
fi

HIT_COUNT=$(jq 'length' "$BEANPOTS_JSON_PATH")
if ! [[ "$HIT_COUNT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: malformed beanpots array at $BEANPOTS_JSON_PATH" >&2
    exit 1
fi
if [ "$HIT_COUNT" -eq 0 ]; then
    echo "No beanpot hits in window, exiting cleanly."
    exit 0
fi
echo "Processing $HIT_COUNT beanpot hit record(s)..."

if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "DRY_RUN: would push $HIT_COUNT hit(s) to $GITLAWB_BEANPOTS_REPO"
    jq -r '.[] | "\(.hit.closed_at[0:10]) round=\(.hit.round_id) amount=\(.hit.beanpot_amount_bean) BEAN"' "$BEANPOTS_JSON_PATH"
    exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Cloning $GITLAWB_BEANPOTS_REPO ..."
git clone "$GITLAWB_BEANPOTS_REPO" "$WORK_DIR/minebean-beanpots"
cd "$WORK_DIR/minebean-beanpots"

git config user.name "$GITLAWB_DID"
git config user.email "${GITLAWB_DID}@gitlawb"

WRITTEN=0
SKIPPED=0
COMMIT_MSG_LINES=""
for i in $(seq 0 $((HIT_COUNT - 1))); do
    HIT_JSON=$(jq -c ".[$i]" "$BEANPOTS_JSON_PATH")
    ROUND_ID=$(printf '%s' "$HIT_JSON" | jq -r '.hit.round_id')
    CLOSED_AT=$(printf '%s' "$HIT_JSON" | jq -r '.hit.closed_at')

    if [ -z "$ROUND_ID" ] || [ "$ROUND_ID" = "null" ]; then
        echo "ERROR: hit $i missing round_id" >&2
        exit 1
    fi
    if [ -z "$CLOSED_AT" ] || [ "$CLOSED_AT" = "null" ]; then
        echo "ERROR: hit $i missing closed_at" >&2
        exit 1
    fi

    YEAR="${CLOSED_AT:0:4}"
    MONTH="${CLOSED_AT:5:2}"
    DAY="${CLOSED_AT:8:2}"
    TARGET_PATH="hits/${YEAR}/${MONTH}/${DAY}/beanpot-${ROUND_ID}.json"

    if [ -f "$TARGET_PATH" ]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    mkdir -p "$(dirname "$TARGET_PATH")"
    printf '%s\n' "$HIT_JSON" | jq '.' > "$TARGET_PATH"
    git add "$TARGET_PATH"
    WRITTEN=$((WRITTEN + 1))
    COMMIT_MSG_LINES="${COMMIT_MSG_LINES}- ${TARGET_PATH}"$'\n'
done

echo "Wrote ${WRITTEN} new hit file(s), skipped ${SKIPPED} pre-existing."

if [ "$WRITTEN" -eq 0 ]; then
    echo "Nothing new to commit, exiting cleanly."
    exit 0
fi

if [ "$WRITTEN" -eq 1 ]; then
    ONLY_PATH=$(printf '%s' "$COMMIT_MSG_LINES" | head -1 | sed 's/^- //')
    git commit -m "beanpots: ${ONLY_PATH}"
else
    git commit -m "beanpots: ${WRITTEN} new hit(s)" \
               -m "$(printf '%s' "$COMMIT_MSG_LINES")"
fi

PUSH_MAX_ATTEMPTS=3
for attempt in $(seq 1 "$PUSH_MAX_ATTEMPTS"); do
    if git push origin main; then
        echo "Pushed ${WRITTEN} new hit file(s) (attempt $attempt)"
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
