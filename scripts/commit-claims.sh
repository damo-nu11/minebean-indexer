#!/usr/bin/env bash
# commit-claims.sh
#
# Takes the JSON array emitted by fetch-claims.sh and pushes any NEW claim
# files to the minebean-claims Gitlawb repo. Skips any file that already
# exists in the repo (append-only invariant from SCHEMA.md).
#
# Required env:
#   CLAIMS_JSON_PATH         path to the claims array file
#   GITLAWB_CLAIMS_REPO      gitlawb:// URL of minebean-claims
#   GITLAWB_DID              the DID stamped into commit author
# Optional env:
#   DRY_RUN                  if "true", logs intended action without pushing

set -euo pipefail

: "${CLAIMS_JSON_PATH:?CLAIMS_JSON_PATH is required}"
: "${GITLAWB_CLAIMS_REPO:?GITLAWB_CLAIMS_REPO is required}"
: "${GITLAWB_DID:?GITLAWB_DID is required}"

if [ ! -f "$CLAIMS_JSON_PATH" ]; then
    echo "ERROR: claims file not found at $CLAIMS_JSON_PATH" >&2
    exit 1
fi

CLAIM_COUNT=$(jq 'length' "$CLAIMS_JSON_PATH")
if ! [[ "$CLAIM_COUNT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: malformed claims array at $CLAIMS_JSON_PATH" >&2
    exit 1
fi
if [ "$CLAIM_COUNT" -eq 0 ]; then
    echo "No new claims in window, exiting cleanly."
    exit 0
fi
echo "Processing $CLAIM_COUNT claim record(s)..."

if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "DRY_RUN: would push $CLAIM_COUNT claim(s) to $GITLAWB_CLAIMS_REPO"
    jq -r '.[] | "\(.claim.claimed_at[0:10]) tx=\(.claim.tx_hash) idx=\(.claim.event_index)"' "$CLAIMS_JSON_PATH"
    exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Cloning $GITLAWB_CLAIMS_REPO ..."
git clone "$GITLAWB_CLAIMS_REPO" "$WORK_DIR/minebean-claims"
cd "$WORK_DIR/minebean-claims"

git config user.name "$GITLAWB_DID"
git config user.email "${GITLAWB_DID}@gitlawb"

# Walk every claim, write to its target path if it doesn't already exist.
# Track which were newly written so we know whether to commit + push.
WRITTEN=0
SKIPPED=0
COMMIT_MSG_LINES=""
for i in $(seq 0 $((CLAIM_COUNT - 1))); do
    CLAIM_JSON=$(jq -c ".[$i]" "$CLAIMS_JSON_PATH")
    TX_HASH=$(printf '%s' "$CLAIM_JSON"   | jq -r '.claim.tx_hash')
    EVENT_IDX=$(printf '%s' "$CLAIM_JSON" | jq -r '.claim.event_index')
    CLAIMED_AT=$(printf '%s' "$CLAIM_JSON" | jq -r '.claim.claimed_at')

    if [ -z "$TX_HASH" ] || [ "$TX_HASH" = "null" ]; then
        echo "ERROR: claim $i missing tx_hash" >&2
        exit 1
    fi
    if [ -z "$EVENT_IDX" ] || [ "$EVENT_IDX" = "null" ]; then
        echo "ERROR: claim $i missing event_index" >&2
        exit 1
    fi
    if [ -z "$CLAIMED_AT" ] || [ "$CLAIMED_AT" = "null" ]; then
        echo "ERROR: claim $i missing claimed_at" >&2
        exit 1
    fi

    YEAR="${CLAIMED_AT:0:4}"
    MONTH="${CLAIMED_AT:5:2}"
    DAY="${CLAIMED_AT:8:2}"
    TARGET_PATH="claims/${YEAR}/${MONTH}/${DAY}/claim-${TX_HASH}-${EVENT_IDX}.json"

    if [ -f "$TARGET_PATH" ]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    mkdir -p "$(dirname "$TARGET_PATH")"
    printf '%s\n' "$CLAIM_JSON" | jq '.' > "$TARGET_PATH"
    git add "$TARGET_PATH"
    WRITTEN=$((WRITTEN + 1))
    COMMIT_MSG_LINES="${COMMIT_MSG_LINES}- ${TARGET_PATH}"$'\n'
done

echo "Wrote ${WRITTEN} new claim file(s), skipped ${SKIPPED} pre-existing."

if [ "$WRITTEN" -eq 0 ]; then
    echo "Nothing new to commit, exiting cleanly."
    exit 0
fi

if [ "$WRITTEN" -eq 1 ]; then
    # Single-claim: target path in the subject for grep-ability, no body.
    ONLY_PATH=$(printf '%s' "$COMMIT_MSG_LINES" | head -1 | sed 's/^- //')
    git commit -m "claims: ${ONLY_PATH}"
else
    git commit -m "claims: ${WRITTEN} new ClaimedBEAN event(s)" \
               -m "$(printf '%s' "$COMMIT_MSG_LINES")"
fi

# Push with retry+rebase, same pattern as commit-window.sh / commit-nostradamus.sh.
PUSH_MAX_ATTEMPTS=3
for attempt in $(seq 1 "$PUSH_MAX_ATTEMPTS"); do
    if git push origin main; then
        echo "Pushed ${WRITTEN} new claim file(s) (attempt $attempt)"
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
