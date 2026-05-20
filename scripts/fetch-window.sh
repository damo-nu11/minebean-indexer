#!/usr/bin/env bash
# fetch-window.sh
#
# Reads the last 5 fully-settled rounds from the GridMining contract on Base
# and writes a window JSON file to stdout (or to $OUTPUT_PATH if set).
#
# Required env:
#   BASE_RPC_URL
#   GITLAWB_PSEUDONYM_SALT  hex string used to derive pseudonyms
# Optional env:
#   ROUNDS_PER_WINDOW       default 5
#   INDEXER_VERSION         default 0.1.0

set -euo pipefail

: "${BASE_RPC_URL:?BASE_RPC_URL is required}"
: "${GITLAWB_PSEUDONYM_SALT:?GITLAWB_PSEUDONYM_SALT is required}"

GRID_MINING="0x9632495bDb93FD6B0740Ab69cc6c71C9c01da4f0"
BEAN_TOKEN="0x5c72992b83E74c4D5200A8E8920fB946214a5A5D"
ROUNDS_PER_WINDOW="${ROUNDS_PER_WINDOW:-5}"
INDEXER_VERSION="${INDEXER_VERSION:-0.1.0}"

# Extract first whitespace-separated token from a cast call output (strips
# scientific notation annotations like "103861 [1.038e5]")
first_tok() {
    awk '{print $1}'
}

# Convert a unix timestamp (seconds) to ISO 8601 UTC
ts_to_iso() {
    # macOS BSD date and GNU date both accept different flags; try both.
    date -u -r "$1" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ"
}

# Compute pseudonym for an address using keccak256(address || salt)[:8]
# The salt is provided as a hex string in GITLAWB_PSEUDONYM_SALT.
pseudonym_for() {
    local addr="$1"
    if [ -z "$addr" ] || [ "$addr" = "0x0000000000000000000000000000000000000000" ]; then
        printf 'null'
        return
    fi
    local addr_hex="${addr#0x}"
    local salt_hex="${GITLAWB_PSEUDONYM_SALT#0x}"
    local combined="0x${addr_hex}${salt_hex}"
    local hash
    hash="$(cast keccak "$combined")"
    # first 8 chars after the 0x
    printf '"%s"' "${hash:2:8}"
}

# Read a single round's data via the rounds() mapping
# Output: caller-readable JSON object for the round, or empty if not settled
fetch_round() {
    local round_id="$1"
    local raw
    raw=$(cast call "$GRID_MINING" \
        "rounds(uint64)(uint256,uint256,uint256,uint256,uint256,uint8,address,uint256,uint256,uint256,uint256,bool,uint256)" \
        "$round_id" \
        --rpc-url "$BASE_RPC_URL" 2>/dev/null) || return 1

    # cast returns one field per line
    local start_time end_time total_deployed total_winnings winners_deployed
    local winning_block top_miner top_miner_reward beanpot_amount vrf_request_id
    local top_miner_seed settled miner_count

    start_time=$(echo "$raw"        | sed -n '1p'  | first_tok)
    end_time=$(echo "$raw"          | sed -n '2p'  | first_tok)
    total_deployed=$(echo "$raw"    | sed -n '3p'  | first_tok)
    total_winnings=$(echo "$raw"    | sed -n '4p'  | first_tok)
    winners_deployed=$(echo "$raw"  | sed -n '5p'  | first_tok)
    winning_block=$(echo "$raw"     | sed -n '6p'  | first_tok)
    top_miner=$(echo "$raw"         | sed -n '7p'  | first_tok)
    top_miner_reward=$(echo "$raw"  | sed -n '8p'  | first_tok)
    beanpot_amount=$(echo "$raw"    | sed -n '9p'  | first_tok)
    vrf_request_id=$(echo "$raw"    | sed -n '10p' | first_tok)
    top_miner_seed=$(echo "$raw"    | sed -n '11p' | first_tok)
    settled=$(echo "$raw"           | sed -n '12p' | first_tok)
    miner_count=$(echo "$raw"       | sed -n '13p' | first_tok)

    # Only emit settled rounds
    if [ "$settled" != "true" ]; then
        return 1
    fi

    local closed_at
    closed_at=$(ts_to_iso "$end_time")

    local beanpot_hit="false"
    local beanpot_winner_pseudonym="null"
    if [ "$beanpot_amount" != "0" ]; then
        beanpot_hit="true"
        beanpot_winner_pseudonym="$(pseudonym_for "$top_miner")"
    fi

    # Grid state hash: keccak256 of the packed getRoundDeployed() array
    local grid_deployed
    grid_deployed=$(cast call "$GRID_MINING" \
        "getRoundDeployed(uint64)(uint256[25])" \
        "$round_id" \
        --rpc-url "$BASE_RPC_URL" 2>/dev/null || echo "")
    local grid_state_hash="null"
    if [ -n "$grid_deployed" ]; then
        # Hash the raw output string (deterministic enough for tamper detection)
        local packed
        packed=$(echo -n "$grid_deployed" | xxd -p | tr -d '\n')
        if [ -n "$packed" ]; then
            grid_state_hash="\"$(cast keccak "0x${packed}")\""
        fi
    fi

    cat <<JSON
    {
      "round_id": ${round_id},
      "closed_at": "${closed_at}",
      "winning_block": ${winning_block},
      "miner_count": ${miner_count},
      "total_deployed_wei": "${total_deployed}",
      "total_winnings_wei": "${total_winnings}",
      "winners_deployed": ${winners_deployed},
      "beanpot_amount_wei": "${beanpot_amount}",
      "beanpot_hit": ${beanpot_hit},
      "beanpot_winner_pseudonym": ${beanpot_winner_pseudonym},
      "grid_state_hash": ${grid_state_hash}
    }
JSON
}

# Get the latest fully-settled round ID
get_latest_settled_round() {
    local current
    current=$(cast call "$GRID_MINING" \
        "currentRoundId()(uint64)" \
        --rpc-url "$BASE_RPC_URL" | first_tok)
    # currentRoundId is the round IN PROGRESS, so the last settled is current - 1
    echo $((current - 1))
}

main() {
    local latest_round
    latest_round=$(get_latest_settled_round)

    if [ "$latest_round" -lt "$ROUNDS_PER_WINDOW" ]; then
        echo "ERROR: not enough rounds yet (need $ROUNDS_PER_WINDOW, have $latest_round)" >&2
        exit 1
    fi

    local first_round=$((latest_round - ROUNDS_PER_WINDOW + 1))
    local last_round=$latest_round

    # Collect round JSONs
    local round_jsons=""
    local total_rounds=0
    local total_deployed_window=0
    local beanpot_hits=0
    local round_id
    for ((round_id=first_round; round_id<=last_round; round_id++)); do
        local round_json
        if ! round_json=$(fetch_round "$round_id"); then
            echo "WARN: skipping round $round_id (not settled or fetch failed)" >&2
            continue
        fi
        if [ -n "$round_jsons" ]; then
            round_jsons="${round_jsons},"$'\n'"${round_json}"
        else
            round_jsons="${round_json}"
        fi
        total_rounds=$((total_rounds + 1))
        # Parse this round's totals back from the JSON we just emitted
        local rd_dep rd_bp
        rd_dep=$(printf '%s' "$round_json" | grep -m1 '"total_deployed_wei"' | sed -E 's/.*"total_deployed_wei"[[:space:]]*:[[:space:]]*"([0-9]+)".*/\1/')
        rd_bp=$(printf '%s' "$round_json" | grep -m1 '"beanpot_hit"' | sed -E 's/.*"beanpot_hit"[[:space:]]*:[[:space:]]*(true|false).*/\1/')
        if [ -n "$rd_dep" ]; then
            # Use bc for big-int addition since wei values exceed bash's 64-bit signed range
            total_deployed_window=$(echo "$total_deployed_window + $rd_dep" | bc)
        fi
        if [ "$rd_bp" = "true" ]; then
            beanpot_hits=$((beanpot_hits + 1))
        fi
    done

    if [ -z "$round_jsons" ]; then
        echo "ERROR: no settled rounds collected" >&2
        exit 1
    fi

    # Window timestamps anchored on the last round's close time
    local last_end_time
    last_end_time=$(cast call "$GRID_MINING" \
        "rounds(uint64)(uint256,uint256,uint256,uint256,uint256,uint8,address,uint256,uint256,uint256,uint256,bool,uint256)" \
        "$last_round" \
        --rpc-url "$BASE_RPC_URL" | sed -n '2p' | first_tok)

    # Window starts at last_end_time - (ROUNDS_PER_WINDOW * 60)
    local window_start_ts=$((last_end_time - ROUNDS_PER_WINDOW * 60))
    local window_end_ts=$last_end_time
    local window_start_iso
    local window_end_iso
    window_start_iso=$(ts_to_iso "$window_start_ts")
    window_end_iso=$(ts_to_iso "$window_end_ts")

    local output
    output=$(cat <<JSON
{
  "schema_version": "0.1.0",
  "window_start": "${window_start_iso}",
  "window_end": "${window_end_iso}",
  "round_range": {
    "first": ${first_round},
    "last": ${last_round}
  },
  "network": "base",
  "contracts": {
    "grid_mining": "${GRID_MINING}",
    "bean_token": "${BEAN_TOKEN}"
  },
  "rounds": [
${round_jsons}
  ],
  "window_aggregates": {
    "total_rounds": ${total_rounds},
    "total_deployed_wei": "${total_deployed_window}",
    "beanpot_hits": ${beanpot_hits}
  },
  "indexer_version": "${INDEXER_VERSION}"
}
JSON
)

    if [ -n "${OUTPUT_PATH:-}" ]; then
        printf '%s' "$output" > "$OUTPUT_PATH"
        echo "Wrote window to $OUTPUT_PATH" >&2
    else
        printf '%s\n' "$output"
    fi
}

main "$@"
