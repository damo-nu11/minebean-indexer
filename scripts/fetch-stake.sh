#!/usr/bin/env bash
# fetch-stake.sh
#
# Reads BEAN.balanceOf(staking) and BEAN.totalSupply() at the current chain
# tip, computes the staked-supply fraction, and emits a single snapshot JSON
# conforming to minebean-stake SCHEMA 0.1.0.
#
# Required env:
#   BASE_RPC_URL
# Optional env:
#   GITLAWB_DID              stamped into signer_did
#   OUTPUT_PATH              where to write the snapshot JSON (else stdout)

set -euo pipefail

: "${BASE_RPC_URL:?BASE_RPC_URL is required}"

STAKING="0xfe177128Df8d336cAf99F787b72183D1E68Ff9c2"
BEAN_TOKEN="0x5c72992b83E74c4D5200A8E8920fB946214a5A5D"
SCHEMA_VERSION="0.1.0"
SIGNER_DID="${GITLAWB_DID:-did:key:z6MkwVfgaAnuypajisEkJLkVbWPiPEBwceMkGutfXpEEYHKi}"

first_tok() {
    awk '{print $1}'
}

is_uint_dec() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

now_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Read chain tip + block hash + timestamp. Snapshot all reads at the SAME
# block so the staked-vs-supply ratio is internally consistent.
get_chain_tip_info() {
    local raw
    if ! raw=$(cast block-number --rpc-url "$BASE_RPC_URL" 2>&1); then
        echo "ERROR: cast block-number failed: $raw" >&2
        return 1
    fi
    local bn
    bn=$(echo "$raw" | first_tok)
    if ! is_uint_dec "$bn"; then
        echo "ERROR: malformed block-number output: $raw" >&2
        return 1
    fi
    local raw_block
    if ! raw_block=$(cast block "$bn" --json --rpc-url "$BASE_RPC_URL" 2>&1); then
        echo "ERROR: cast block $bn failed: $raw_block" >&2
        return 1
    fi
    local ts bh
    ts=$(printf '%s' "$raw_block" | jq -r '.timestamp // empty')
    bh=$(printf '%s' "$raw_block" | jq -r '.hash // empty')
    if [[ "$ts" =~ ^0x[0-9a-fA-F]+$ ]]; then
        ts=$(python3 -c "import sys; print(int(sys.argv[1], 16))" "$ts")
    fi
    if ! is_uint_dec "$ts" || [[ ! "$bh" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
        echo "ERROR: malformed block $bn fields ts=$ts hash=$bh" >&2
        return 1
    fi
    printf '%s\t%s\t%s\n' "$bn" "$bh" "$ts"
}

read_bean_balance_at() {
    local addr="$1"
    local block="$2"
    local raw
    if ! raw=$(cast call "$BEAN_TOKEN" \
        "balanceOf(address)(uint256)" \
        "$addr" \
        --block "$block" \
        --rpc-url "$BASE_RPC_URL" 2>&1); then
        echo "ERROR: BEAN.balanceOf failed for $addr at block $block: $raw" >&2
        return 1
    fi
    local val
    val=$(echo "$raw" | first_tok)
    if ! is_uint_dec "$val"; then
        echo "ERROR: malformed BEAN.balanceOf output: $raw" >&2
        return 1
    fi
    echo "$val"
}

read_bean_total_supply_at() {
    local block="$1"
    local raw
    if ! raw=$(cast call "$BEAN_TOKEN" \
        "totalSupply()(uint256)" \
        --block "$block" \
        --rpc-url "$BASE_RPC_URL" 2>&1); then
        echo "ERROR: BEAN.totalSupply failed at block $block: $raw" >&2
        return 1
    fi
    local val
    val=$(echo "$raw" | first_tok)
    if ! is_uint_dec "$val"; then
        echo "ERROR: malformed BEAN.totalSupply output: $raw" >&2
        return 1
    fi
    echo "$val"
}

main() {
    local tip_info
    if ! tip_info=$(get_chain_tip_info); then
        echo "ERROR: failed to read chain tip info, aborting" >&2
        exit 1
    fi
    local block_number block_hash block_ts
    IFS=$'\t' read -r block_number block_hash block_ts <<< "$tip_info"

    local staked_wei total_wei
    if ! staked_wei=$(read_bean_balance_at "$STAKING" "$block_number"); then
        echo "ERROR: failed to read staked BEAN balance" >&2
        exit 1
    fi
    if ! total_wei=$(read_bean_total_supply_at "$block_number"); then
        echo "ERROR: failed to read BEAN total supply" >&2
        exit 1
    fi

    local snapshot_at
    snapshot_at=$(python3 -c "
from datetime import datetime, timezone
import sys
ts = int(sys.argv[1])
print(datetime.fromtimestamp(ts, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$block_ts")

    echo "Snapshotting stake state at block ${block_number} (${snapshot_at})" >&2
    echo "  staked=${staked_wei} wei, total_supply=${total_wei} wei" >&2

    local indexed_at
    indexed_at=$(now_iso)

    local output
    output=$(
        STAKE_SCHEMA_VERSION="$SCHEMA_VERSION" \
        STAKE_STAKING_ADDR="$STAKING" \
        STAKE_BEAN_TOKEN="$BEAN_TOKEN" \
        STAKE_AT="$snapshot_at" \
        STAKE_BLOCK_NUMBER="$block_number" \
        STAKE_BLOCK_HASH="$block_hash" \
        STAKE_STAKED_WEI="$staked_wei" \
        STAKE_TOTAL_WEI="$total_wei" \
        STAKE_SIGNER_DID="$SIGNER_DID" \
        STAKE_INDEXED_AT="$indexed_at" \
        python3 - <<'PYEOF'
import json
import os
from decimal import Decimal, ROUND_HALF_UP

def wei_to_bean_str(wei: int) -> str:
    d = Decimal(wei) / Decimal(10 ** 18)
    q = d.quantize(Decimal("0.0001"), rounding=ROUND_HALF_UP)
    return f"{q:.4f}"

staked_wei = int(os.environ["STAKE_STAKED_WEI"])
total_wei  = int(os.environ["STAKE_TOTAL_WEI"])

# supply_staked_fraction = staked / total, half-up rounded to 4 decimals.
# Guard against total_supply == 0 (degenerate but possible at chain genesis).
if total_wei == 0:
    fraction_str = "0.0000"
else:
    frac = Decimal(staked_wei) / Decimal(total_wei)
    frac_q = frac.quantize(Decimal("0.0001"), rounding=ROUND_HALF_UP)
    fraction_str = f"{frac_q:.4f}"

doc = {
    "schema_version": os.environ["STAKE_SCHEMA_VERSION"],
    "network": "base-mainnet",
    "chain_id": 8453,
    "snapshot_at":  os.environ["STAKE_AT"],
    "block_number": int(os.environ["STAKE_BLOCK_NUMBER"]),
    "block_hash":   os.environ["STAKE_BLOCK_HASH"],
    "signer_did":   os.environ["STAKE_SIGNER_DID"],
    "indexed_at":   os.environ["STAKE_INDEXED_AT"],
    "contracts": {
        "staking":    os.environ["STAKE_STAKING_ADDR"],
        "bean_token": os.environ["STAKE_BEAN_TOKEN"],
    },
    "state": {
        "staked_bean_wei":        str(staked_wei),
        "staked_bean":            wei_to_bean_str(staked_wei),
        "total_supply_wei":       str(total_wei),
        "total_supply":           wei_to_bean_str(total_wei),
        "supply_staked_fraction": fraction_str,
        # 0.1.0 leaves these null per SCHEMA. A later version backfills both.
        "staker_count": None,
        "paused":       None,
    },
}
print(json.dumps(doc, indent=2, sort_keys=False))
PYEOF
    )

    if [ -n "${OUTPUT_PATH:-}" ]; then
        printf '%s\n' "$output" > "$OUTPUT_PATH"
        echo "Wrote stake snapshot to $OUTPUT_PATH" >&2
    else
        printf '%s\n' "$output"
    fi
}

main "$@"
