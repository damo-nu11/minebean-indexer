#!/usr/bin/env bash
# fetch-vaults.sh
#
# Reads ETH + BEAN balances for the three MineBean vaults on Base mainnet
# at the current chain tip, and emits a single snapshot JSON file conforming
# to minebean-vaults SCHEMA 0.1.0.
#
# Vaults snapshotted (addresses from minebean-contracts/contracts.json):
#   - auto_miner          0x31358496900D600B2f523d6EdC4933E78F72De89
#   - anti_loser_vault    0xA5e8275B132686BfD0Fc60094aE4a02635716f05
#   - nostradamus_vault   0x1098f65b0529E7E78cE8749621e3F0427b2a37f6
#
# Per-vault fields populated in 0.1.0: name, address, role,
# eth_balance_wei, bean_balance_wei. The remaining fields
# (depositor_count, max_deploy_bps, paused, active_strategy) are emitted
# as null per SCHEMA, pending contract-method confirmation in a later
# schema version.
#
# Required env:
#   BASE_RPC_URL
# Optional env:
#   GITLAWB_DID              stamped into signer_did
#   OUTPUT_PATH              where to write the snapshot JSON (else stdout)

set -euo pipefail

: "${BASE_RPC_URL:?BASE_RPC_URL is required}"

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

# Triplet: name, address, role. Order is the on-disk emit order.
VAULT_NAMES=("auto_miner" "anti_loser_vault" "nostradamus_vault")
VAULT_ADDRS=(
    "0x31358496900D600B2f523d6EdC4933E78F72De89"
    "0xA5e8275B132686BfD0Fc60094aE4a02635716f05"
    "0x1098f65b0529E7E78cE8749621e3F0427b2a37f6"
)
VAULT_ROLES=(
    "Auto-miner pooled deployer: aggregates depositor ETH and submits deploys on their behalf."
    "Anti-loser strategy vault: holds depositor ETH and submits per-round deploys via the Anti-Loser strategy."
    "Nostradamus strategy vault: holds depositor ETH and submits per-round deploys via the Nostradamus closed-form EV strategy."
)

# Read chain tip block number + hash. Snapshot all vault reads at the SAME
# block to ensure internal consistency of the snapshot.
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
    # Emit: block_number \t block_hash \t timestamp
    printf '%s\t%s\t%s\n' "$bn" "$bh" "$ts"
}

# cast balance for a given address at a given block. Returns wei as a decimal
# string. Pinned to the snapshot block for internal consistency.
read_eth_balance_at() {
    local addr="$1"
    local block="$2"
    local raw
    if ! raw=$(cast balance "$addr" --block "$block" --rpc-url "$BASE_RPC_URL" 2>&1); then
        echo "ERROR: cast balance failed for $addr at block $block: $raw" >&2
        return 1
    fi
    local val
    val=$(echo "$raw" | first_tok)
    if ! is_uint_dec "$val"; then
        echo "ERROR: malformed balance output for $addr: $raw" >&2
        return 1
    fi
    echo "$val"
}

# BEAN.balanceOf(vault) at the snapshot block.
read_bean_balance_at() {
    local addr="$1"
    local block="$2"
    local raw
    if ! raw=$(cast call "$BEAN_TOKEN" \
        "balanceOf(address)(uint256)" \
        "$addr" \
        --block "$block" \
        --rpc-url "$BASE_RPC_URL" 2>&1); then
        echo "ERROR: cast call BEAN.balanceOf failed for $addr at block $block: $raw" >&2
        return 1
    fi
    local val
    val=$(echo "$raw" | first_tok)
    if ! is_uint_dec "$val"; then
        echo "ERROR: malformed BEAN.balanceOf output for $addr: $raw" >&2
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

    local snapshot_at
    snapshot_at=$(python3 -c "
from datetime import datetime, timezone
import sys
ts = int(sys.argv[1])
print(datetime.fromtimestamp(ts, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$block_ts")

    echo "Snapshotting vaults at block ${block_number} (${snapshot_at})" >&2

    # Read all three vaults at the same block.
    local vault_jsons=""
    local i
    for i in 0 1 2; do
        local name="${VAULT_NAMES[$i]}"
        local addr="${VAULT_ADDRS[$i]}"
        local role="${VAULT_ROLES[$i]}"
        local eth_wei bean_wei
        if ! eth_wei=$(read_eth_balance_at "$addr" "$block_number"); then
            echo "ERROR: failed to read ETH balance for $name ($addr)" >&2
            exit 1
        fi
        if ! bean_wei=$(read_bean_balance_at "$addr" "$block_number"); then
            echo "ERROR: failed to read BEAN balance for $name ($addr)" >&2
            exit 1
        fi
        local entry
        entry=$(
            VAULT_NAME="$name" \
            VAULT_ADDR="$addr" \
            VAULT_ROLE="$role" \
            VAULT_ETH_WEI="$eth_wei" \
            VAULT_BEAN_WEI="$bean_wei" \
            python3 - <<'PYEOF'
import json
import os

print(json.dumps({
    "name":             os.environ["VAULT_NAME"],
    "address":          os.environ["VAULT_ADDR"],
    "role":             os.environ["VAULT_ROLE"],
    "eth_balance_wei":  os.environ["VAULT_ETH_WEI"],
    "bean_balance_wei": os.environ["VAULT_BEAN_WEI"],
    # 0.1.0 leaves these null per SCHEMA. A later schema bump will populate
    # them after the contract methods are confirmed against the deployed ABI.
    "depositor_count":  None,
    "max_deploy_bps":   None,
    "paused":           None,
    "active_strategy":  None,
}, indent=2))
PYEOF
        )
        if [ -n "$vault_jsons" ]; then
            vault_jsons="${vault_jsons},"$'\n'"${entry}"
        else
            vault_jsons="$entry"
        fi
    done

    local indexed_at
    indexed_at=$(now_iso)

    local output
    output=$(
        SNAP_SCHEMA_VERSION="$SCHEMA_VERSION" \
        SNAP_AT="$snapshot_at" \
        SNAP_BLOCK_NUMBER="$block_number" \
        SNAP_BLOCK_HASH="$block_hash" \
        SNAP_SIGNER_DID="$SIGNER_DID" \
        SNAP_VAULTS="$vault_jsons" \
        SNAP_INDEXED_AT="$indexed_at" \
        python3 - <<'PYEOF'
import json
import os

doc = {
    "schema_version": os.environ["SNAP_SCHEMA_VERSION"],
    "network": "base-mainnet",
    "chain_id": 8453,
    "snapshot_at": os.environ["SNAP_AT"],
    "block_number": int(os.environ["SNAP_BLOCK_NUMBER"]),
    "block_hash":   os.environ["SNAP_BLOCK_HASH"],
    "signer_did":   os.environ["SNAP_SIGNER_DID"],
    "indexed_at":   os.environ["SNAP_INDEXED_AT"],
    "vaults": json.loads("[" + os.environ["SNAP_VAULTS"] + "]"),
}
print(json.dumps(doc, indent=2, sort_keys=False))
PYEOF
    )

    if [ -n "${OUTPUT_PATH:-}" ]; then
        printf '%s\n' "$output" > "$OUTPUT_PATH"
        echo "Wrote vault snapshot to $OUTPUT_PATH" >&2
    else
        printf '%s\n' "$output"
    fi
}

main "$@"
