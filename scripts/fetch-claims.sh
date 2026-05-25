#!/usr/bin/env bash
# fetch-claims.sh
#
# Scans the last LOOKBACK_BLOCKS of Base mainnet for ClaimedBEAN events on
# the MineBean GridMining contract, decodes each one, and emits a JSON array
# of claim records ready for commit-claims.sh.
#
# Event: ClaimedBEAN(address user, uint256 minedBean, uint256 roastedBean,
#                    uint256 fee, uint256 net)
# topics[0] = keccak256 of the canonical signature above
# topics[1] = 32-byte left-padded claimer address
# data      = 4 uint256 packed: minedBean, roastedBean, fee, net
#
# Required env:
#   BASE_RPC_URL
#   GITLAWB_PSEUDONYM_SALT   hex (matches rounds indexer convention)
# Optional env:
#   LOOKBACK_BLOCKS          default 300  (~10 min on Base @ ~2s blocks)
#   OUTPUT_PATH              where to write the JSON array (else stdout)

set -euo pipefail

: "${BASE_RPC_URL:?BASE_RPC_URL is required}"
: "${GITLAWB_PSEUDONYM_SALT:?GITLAWB_PSEUDONYM_SALT is required}"

GRID_MINING="0x9632495bDb93FD6B0740Ab69cc6c71C9c01da4f0"
BEAN_TOKEN="0x5c72992b83E74c4D5200A8E8920fB946214a5A5D"
LOOKBACK_BLOCKS="${LOOKBACK_BLOCKS:-300}"
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

# Get the chain head.
get_chain_tip() {
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
    echo "$bn"
}

main() {
    local tip
    if ! tip=$(get_chain_tip); then
        echo "ERROR: failed to read chain tip, aborting" >&2
        exit 1
    fi
    if ! [[ "$tip" =~ ^[0-9]+$ ]]; then
        echo "ERROR: chain tip not a positive integer: $tip" >&2
        exit 1
    fi
    local from_block
    from_block=$((tip - LOOKBACK_BLOCKS))
    if [ "$from_block" -lt 0 ]; then from_block=0; fi

    echo "Scanning blocks ${from_block}..${tip} for ClaimedBEAN events" >&2

    # cast logs with the event signature handles topic0 computation. --json
    # returns raw log objects (topics, data, blockNumber, transactionHash,
    # logIndex, etc.) which we decode below.
    local raw_logs
    if ! raw_logs=$(cast logs \
        --from-block "$from_block" --to-block "$tip" \
        --address "$GRID_MINING" \
        "ClaimedBEAN(address,uint256,uint256,uint256,uint256)" \
        --rpc-url "$BASE_RPC_URL" \
        --json 2>&1); then
        echo "ERROR: cast logs failed: $raw_logs" >&2
        exit 1
    fi

    # If no events in the window, emit an empty array and exit cleanly. The
    # commit script handles "nothing to do" gracefully.
    local log_count
    log_count=$(printf '%s' "$raw_logs" | jq 'length')
    echo "Found ${log_count} ClaimedBEAN event(s) in window" >&2

    # cast logs --json includes blockTimestamp and blockHash directly in each
    # log object (verified against Base mainnet 2026-05-25), so we don't need
    # a separate cast block call per unique block. Python decodes everything
    # in one pass.
    local output
    output=$(
        CLAIMS_RAW_LOGS="$raw_logs" \
        CLAIMS_GRID_MINING="$GRID_MINING" \
        CLAIMS_BEAN_TOKEN="$BEAN_TOKEN" \
        CLAIMS_SCHEMA_VERSION="$SCHEMA_VERSION" \
        CLAIMS_PSEUDONYM_SALT="$GITLAWB_PSEUDONYM_SALT" \
        CLAIMS_SIGNER_DID="$SIGNER_DID" \
        CLAIMS_INDEXED_AT="$(now_iso)" \
        python3 - <<'PYEOF'
import json
import os
import hashlib
from datetime import datetime, timezone

raw_logs        = json.loads(os.environ["CLAIMS_RAW_LOGS"])
grid_mining     = os.environ["CLAIMS_GRID_MINING"]
bean_token      = os.environ["CLAIMS_BEAN_TOKEN"]
schema_version  = os.environ["CLAIMS_SCHEMA_VERSION"]
salt_hex        = os.environ["CLAIMS_PSEUDONYM_SALT"].removeprefix("0x")
signer_did      = os.environ["CLAIMS_SIGNER_DID"]
indexed_at      = os.environ["CLAIMS_INDEXED_AT"]

def keccak(b: bytes) -> str:
    # Use pycryptodome if available, else fall back to a pure-python keccak.
    # Standard library hashlib does NOT include keccak-256 (sha3_256 is FIPS).
    # We need keccak-256 as used by Ethereum.
    try:
        from Crypto.Hash import keccak as keccak_mod
        k = keccak_mod.new(digest_bits=256)
        k.update(b)
        return k.hexdigest()
    except ImportError:
        pass
    # Fallback: invoke `cast keccak` via subprocess for each call. Slower
    # but works in any environment that has foundry installed (which we do).
    import subprocess
    hex_in = "0x" + b.hex()
    res = subprocess.run(
        ["cast", "keccak", hex_in],
        capture_output=True, text=True, check=True,
    )
    out = res.stdout.strip().split()[0]
    return out.removeprefix("0x")

def hex_to_int(h: str) -> int:
    return int(h, 16) if isinstance(h, str) else int(h)

# Pseudonym matches the rounds indexer convention (fetch-window.sh): the salt
# is interpreted as a HEX string and concatenated with the lowercased 20-byte
# address (also as hex). The first 8 hex chars (4 bytes) of the keccak256 of
# the concatenation are the pseudonym. Stable across all MineBean Gitlawb
# repos because every indexer applies this identical scheme.
def pseudonym_for(addr_hex: str) -> str | None:
    if not addr_hex or addr_hex.lower() == "0x" + "00" * 20:
        return None
    addr_clean = addr_hex.lower().removeprefix("0x")
    if len(addr_clean) != 40:
        return None
    combined = bytes.fromhex(addr_clean + salt_hex)
    h = keccak(combined)
    return h[:8]

def wei_to_eth_str(wei: int) -> str:
    # BEAN is ERC20 with 18 decimals (same as ETH). Format with 4 decimal
    # places, half-up rounded, for display use only. Verifier uses _wei.
    from decimal import Decimal, ROUND_HALF_UP
    d = Decimal(wei) / Decimal(10 ** 18)
    q = d.quantize(Decimal("0.0001"), rounding=ROUND_HALF_UP)
    # Strip trailing zeros only if they're past the decimal point; keep
    # exactly 4 decimal places for consistency.
    return f"{q:.4f}"

claims_out = []

for log in raw_logs:
    tx_hash    = log["transactionHash"].lower()
    block_num  = hex_to_int(log["blockNumber"])
    log_index  = hex_to_int(log["logIndex"])
    topics     = log["topics"]
    data       = log["data"].removeprefix("0x")

    if len(topics) < 2:
        # Malformed event; skip with a warning.
        print(f"WARN: log at {tx_hash}:{log_index} has insufficient topics", file=__import__('sys').stderr)
        continue

    # topics[1] is the 32-byte left-padded claimer address.
    claimer_topic = topics[1].lower().removeprefix("0x")
    if len(claimer_topic) != 64:
        print(f"WARN: malformed claimer topic at {tx_hash}:{log_index}", file=__import__('sys').stderr)
        continue
    claimer_addr = "0x" + claimer_topic[-40:]

    # data is exactly 4 uint256 values (32 bytes each = 64 hex chars each).
    if len(data) != 256:
        print(f"WARN: malformed data at {tx_hash}:{log_index}, len={len(data)}", file=__import__('sys').stderr)
        continue
    mined_bean_wei    = int(data[0:64],     16)
    roasted_bean_wei  = int(data[64:128],   16)
    fee_bean_wei      = int(data[128:192],  16)
    net_bean_wei      = int(data[192:256],  16)

    gross_bean_wei    = mined_bean_wei + roasted_bean_wei

    # Sanity invariant: net should equal gross - fee. If the event ever
    # violates this, record it anyway (the file is a faithful record) but
    # surface a warning.
    if net_bean_wei != gross_bean_wei - fee_bean_wei:
        print(
            f"WARN: invariant violation at {tx_hash}:{log_index}: "
            f"net={net_bean_wei} != gross-fee={gross_bean_wei - fee_bean_wei}",
            file=__import__('sys').stderr,
        )

    block_hash = log.get("blockHash", "").lower()
    if not block_hash.startswith("0x") or len(block_hash) != 66:
        print(f"ERROR: malformed blockHash at {tx_hash}:{log_index}: {block_hash}", file=__import__('sys').stderr)
        raise SystemExit(1)

    block_ts_raw = log.get("blockTimestamp")
    if block_ts_raw is None:
        print(f"ERROR: blockTimestamp missing at {tx_hash}:{log_index}", file=__import__('sys').stderr)
        raise SystemExit(1)
    block_ts = hex_to_int(block_ts_raw)
    claimed_at = datetime.fromtimestamp(block_ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    pseudo = pseudonym_for(claimer_addr)
    if pseudo is None:
        print(f"WARN: null pseudonym for {tx_hash}:{log_index}", file=__import__('sys').stderr)
        continue

    claim_doc = {
        "schema_version": schema_version,
        "network": "base-mainnet",
        "chain_id": 8453,
        "type": "bean_roast_claim",
        "contracts": {
            "grid_mining": grid_mining,
            "bean_token": bean_token,
        },
        "claim": {
            "tx_hash": tx_hash,
            "block_number": block_num,
            "block_hash": block_hash,
            "event_index": log_index,
            "claimed_at": claimed_at,
            "claimer_pseudonym": pseudo,
            "mined_bean_wei":    str(mined_bean_wei),
            "roasted_bean_wei":  str(roasted_bean_wei),
            "gross_bean_wei":    str(gross_bean_wei),
            "fee_bean_wei":      str(fee_bean_wei),
            "net_bean_wei":      str(net_bean_wei),
            "mined_bean":   wei_to_eth_str(mined_bean_wei),
            "roasted_bean": wei_to_eth_str(roasted_bean_wei),
            "gross_bean":   wei_to_eth_str(gross_bean_wei),
            "fee_bean":     wei_to_eth_str(fee_bean_wei),
            "net_bean":     wei_to_eth_str(net_bean_wei),
        },
        "indexed_at": indexed_at,
        "signer_did": signer_did,
    }
    claims_out.append(claim_doc)

print(json.dumps(claims_out, indent=2, sort_keys=False))
PYEOF
    )

    if [ -n "${OUTPUT_PATH:-}" ]; then
        printf '%s\n' "$output" > "$OUTPUT_PATH"
        local n
        n=$(printf '%s' "$output" | jq 'length')
        echo "Wrote ${n} claim record(s) to $OUTPUT_PATH" >&2
    else
        printf '%s\n' "$output"
    fi
}

main "$@"
