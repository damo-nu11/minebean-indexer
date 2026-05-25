#!/usr/bin/env bash
# fetch-nostradamus.sh
#
# Builds a per-round Nostradamus decision file for the latest settled round.
# Decision = inputs (bean price + 3-round lookback mean) + closed-form output
# (X* = sqrt(K*P*T) - T) computed in ETH-float space to byte-match the
# canonical strategy at hermes-mine-bean/src/hermes_minebean/strategies.py
# (_nostradamus, _threshold_eth, _optimal_x_eth). deploy_tx and
# actual_deploy_wei are emitted as null in 0.1.x (see SCHEMA "Future schema
# additions" / "Reproducibility tolerance"); a later indexer version will
# backfill them from receipt scans.
#
# Required env:
#   BASE_RPC_URL
# Optional env:
#   BEAN_PRICE_URL          default https://api.minebean.com/api/price
#   GITLAWB_DID             stamped into signer_did
#   TARGET_ROUND            override the target round (default: latest settled)
#   OUTPUT_PATH             where to write JSON (else stdout)

set -euo pipefail

: "${BASE_RPC_URL:?BASE_RPC_URL is required}"

GRID_MINING="0x9632495bDb93FD6B0740Ab69cc6c71C9c01da4f0"
BEAN_TOKEN="0x5c72992b83E74c4D5200A8E8920fB946214a5A5D"
NOSTRADAMUS_VAULT="0x1098f65b0529E7E78cE8749621e3F0427b2a37f6"
BEAN_PRICE_URL="${BEAN_PRICE_URL:-https://api.minebean.com/api/price}"
SCHEMA_VERSION="0.1.0"
SIGNER_DID="${GITLAWB_DID:-did:key:z6MkwVfgaAnuypajisEkJLkVbWPiPEBwceMkGutfXpEEYHKi}"

# Canonical constants from strategies.py:52,67. Recorded verbatim so verifiers
# byte-match the runtime's float math.
B_CONST="1.0"
FEE_DRAG="0.105"
K_FLOAT="9.523809523809524"

# Extract first whitespace-separated token (strips cast annotations like
# "103861 [1.038e5]"). Mirrors fetch-window.sh's defensive parse.
first_tok() {
    awk '{print $1}'
}

ts_to_iso() {
    date -u -r "$1" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ"
}

now_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Regex: numeric decimal (no scientific notation, no nan/inf). Rejects anything
# that could be unsafe to feed to Python `float()` or that diverges from the
# strategies.py contract (it consumes a plain decimal from the price feed).
is_decimal() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

is_uint_dec() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# Read a single round via the rounds() mapping. Emits tab-separated:
#   start_time \t end_time \t total_deployed \t settled
# Returns nonzero if the round is unreadable.
read_round_fields() {
    local round_id="$1"
    local raw
    if ! raw=$(cast call "$GRID_MINING" \
        "rounds(uint64)(uint256,uint256,uint256,uint256,uint256,uint8,address,uint256,uint256,uint256,uint256,bool,uint256)" \
        "$round_id" \
        --rpc-url "$BASE_RPC_URL" 2>&1); then
        echo "ERROR: cast call failed for round $round_id: $raw" >&2
        return 1
    fi
    local start_time end_time total_deployed settled
    start_time=$(echo "$raw"     | sed -n '1p'  | first_tok)
    end_time=$(echo "$raw"       | sed -n '2p'  | first_tok)
    total_deployed=$(echo "$raw" | sed -n '3p'  | first_tok)
    settled=$(echo "$raw"        | sed -n '12p' | first_tok)
    if ! is_uint_dec "$start_time" || ! is_uint_dec "$end_time" || ! is_uint_dec "$total_deployed"; then
        echo "ERROR: malformed cast output for round $round_id" >&2
        return 1
    fi
    if [ "$settled" != "true" ] && [ "$settled" != "false" ]; then
        echo "ERROR: unexpected settled value for round $round_id: $settled" >&2
        return 1
    fi
    printf '%s\t%s\t%s\t%s\n' "$start_time" "$end_time" "$total_deployed" "$settled"
}

get_latest_settled_round() {
    local raw
    if ! raw=$(cast call "$GRID_MINING" \
        "currentRoundId()(uint64)" \
        --rpc-url "$BASE_RPC_URL" 2>&1); then
        echo "ERROR: currentRoundId() call failed: $raw" >&2
        return 1
    fi
    local current
    current=$(echo "$raw" | first_tok)
    if ! is_uint_dec "$current"; then
        echo "ERROR: malformed currentRoundId(): $raw" >&2
        return 1
    fi
    # currentRoundId is IN PROGRESS; last settled is current - 1.
    python3 -c "import sys; print(int(sys.argv[1]) - 1)" "$current"
}

fetch_bean_price_eth() {
    local resp
    if ! resp=$(curl -sf --max-time 10 "$BEAN_PRICE_URL" 2>/dev/null); then
        echo ""
        return
    fi
    local price
    # API shape: { "bean": { "priceNative": "0.006846", ... }, "fetchedAt": ... }
    price=$(printf '%s' "$resp" | jq -r '.bean.priceNative // .priceNative // empty' 2>/dev/null || true)
    if [ -z "$price" ]; then
        echo ""
        return
    fi
    # Strict numeric validation. Reject scientific notation, signed forms,
    # nan/inf, anything that would let an upstream API surprise us.
    if ! is_decimal "$price"; then
        echo "ERROR: BEAN price not a plain decimal: $price" >&2
        echo ""
        return
    fi
    printf '%s' "$price"
}

main() {
    local target_round
    if [ -n "${TARGET_ROUND:-}" ]; then
        if ! is_uint_dec "$TARGET_ROUND"; then
            echo "ERROR: TARGET_ROUND must be a non-negative integer, got: $TARGET_ROUND" >&2
            exit 1
        fi
        target_round="$TARGET_ROUND"
    else
        target_round=$(get_latest_settled_round)
    fi

    if [ "$target_round" -lt 1 ]; then
        echo "ERROR: no settled round to index (latest=$target_round)" >&2
        exit 1
    fi

    # Target round must be readable and settled.
    local fields
    if ! fields=$(read_round_fields "$target_round"); then
        echo "ERROR: failed to read target round $target_round" >&2
        exit 1
    fi
    local start_time end_time _td settled
    IFS=$'\t' read -r start_time end_time _td settled <<< "$fields"
    if [ "$settled" != "true" ]; then
        echo "ERROR: round $target_round not settled yet" >&2
        exit 1
    fi

    # 3-round lookback (R-1, R-2, R-3). Per strategies.py:316 + tools.py
    # feeder. Hard-fail on partial reads rather than silently degrade to
    # cold-start, since immutable files are corruption-by-design.
    local t_sum="0"
    local t_count=0
    if [ "$target_round" -ge 4 ]; then
        local r
        for r in $((target_round - 1)) $((target_round - 2)) $((target_round - 3)); do
            local rf
            if ! rf=$(read_round_fields "$r"); then
                echo "ERROR: lookback round $r unreadable, refusing to publish a misleading decision" >&2
                exit 1
            fi
            local rs rt
            IFS=$'\t' read -r _ _ rt rs <<< "$rf"
            if [ "$rs" != "true" ]; then
                echo "ERROR: lookback round $r not settled, refusing to publish a misleading decision" >&2
                exit 1
            fi
            t_sum=$(python3 -c "import sys; print(int(sys.argv[1]) + int(sys.argv[2]))" "$t_sum" "$rt")
            t_count=$((t_count + 1))
        done
    fi

    # T_wei: arithmetic mean of the 3 lookback totalDeployed values (wei).
    # If we have fewer than 3 (early life of the chain), T_wei = 0 which
    # triggers strategies.py's cold-start branch (t_eth <= 0 → deploy_minimum).
    local t_wei="0"
    if [ "$t_count" -eq 3 ]; then
        t_wei=$(python3 -c "import sys; print(int(sys.argv[1]) // 3)" "$t_sum")
    fi

    # BEAN price.
    local bean_price_eth
    bean_price_eth=$(fetch_bean_price_eth)
    local price_available="true"
    if [ -z "$bean_price_eth" ]; then
        price_available="false"
        bean_price_eth=""
    fi

    # Capture block context BEFORE running the math, so block_number reflects
    # the chain head at input-read time.
    local block_number_field="null"
    local block_hash_field="null"
    local raw_bn
    if raw_bn=$(cast block-number --rpc-url "$BASE_RPC_URL" 2>/dev/null); then
        local bn
        bn=$(echo "$raw_bn" | first_tok)
        if is_uint_dec "$bn"; then
            block_number_field="$bn"
            local raw_bh
            if raw_bh=$(cast block "$bn" --json --rpc-url "$BASE_RPC_URL" 2>/dev/null); then
                local bh
                bh=$(printf '%s' "$raw_bh" | jq -r '.hash // empty' 2>/dev/null || echo "")
                if [[ "$bh" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
                    block_hash_field="\"$bh\""
                fi
            fi
        fi
    fi

    # All math + JSON assembly in one Python pass. Inputs come via env vars
    # (NOT string-interpolated into the Python source), eliminating the
    # shell-injection surface from external API output.
    local decided_at indexed_at
    decided_at=$(ts_to_iso "$start_time")
    indexed_at=$(now_iso)

    local output
    output=$(
        NOSTRA_SCHEMA_VERSION="$SCHEMA_VERSION" \
        NOSTRA_GRID_MINING="$GRID_MINING" \
        NOSTRA_VAULT="$NOSTRADAMUS_VAULT" \
        NOSTRA_BEAN_TOKEN="$BEAN_TOKEN" \
        NOSTRA_ROUND_ID="$target_round" \
        NOSTRA_DECIDED_AT="$decided_at" \
        NOSTRA_INDEXED_AT="$indexed_at" \
        NOSTRA_BLOCK_NUMBER="$block_number_field" \
        NOSTRA_BLOCK_HASH="$block_hash_field" \
        NOSTRA_BEAN_PRICE_ETH="$bean_price_eth" \
        NOSTRA_PRICE_AVAILABLE="$price_available" \
        NOSTRA_T_WEI="$t_wei" \
        NOSTRA_B="$B_CONST" \
        NOSTRA_FEE_DRAG="$FEE_DRAG" \
        NOSTRA_K_FLOAT="$K_FLOAT" \
        NOSTRA_SIGNER_DID="$SIGNER_DID" \
        python3 - <<'PYEOF'
import json
import math
import os

schema_version    = os.environ["NOSTRA_SCHEMA_VERSION"]
grid_mining       = os.environ["NOSTRA_GRID_MINING"]
vault             = os.environ["NOSTRA_VAULT"]
bean_token        = os.environ["NOSTRA_BEAN_TOKEN"]
round_id          = int(os.environ["NOSTRA_ROUND_ID"])
decided_at        = os.environ["NOSTRA_DECIDED_AT"]
indexed_at        = os.environ["NOSTRA_INDEXED_AT"]
block_number_raw  = os.environ["NOSTRA_BLOCK_NUMBER"]
block_hash_raw    = os.environ["NOSTRA_BLOCK_HASH"]
price_str         = os.environ["NOSTRA_BEAN_PRICE_ETH"]
price_available   = os.environ["NOSTRA_PRICE_AVAILABLE"] == "true"
t_wei             = int(os.environ["NOSTRA_T_WEI"])
b_const_str       = os.environ["NOSTRA_B"]
fee_drag_str      = os.environ["NOSTRA_FEE_DRAG"]
k_float_str       = os.environ["NOSTRA_K_FLOAT"]
signer_did        = os.environ["NOSTRA_SIGNER_DID"]

# Reproduce strategies.py exactly: all math in ETH-float space, then convert
# back to wei at the end. Constants match strategies.py:52,67.
K = float(k_float_str)

def wei_to_eth(wei: int) -> float:
    return wei / 1e18

def eth_to_wei(eth: float) -> int:
    return int(eth * 1e18)

action = None
skip_reason = None
x_star_wei = None
threshold_wei = 0
bean_price_eth_wei = 0

if not price_available or not price_str:
    # strategies.py:324-328
    action = "skip"
    skip_reason = "bean_price_eth missing, cannot compute THRESHOLD"
else:
    P_eth = float(price_str)
    # strategies.py runtime converts the upstream priceNative float to wei via
    # int(float * 1e18) for indexing; we record both.
    bean_price_eth_wei = int(P_eth * 1e18)

    if P_eth <= 0:
        # strategies.py:324 also catches a non-positive price here.
        action = "skip"
        skip_reason = "bean_price_eth missing, cannot compute THRESHOLD"
    else:
        # strategies.py:330-331
        t_eth = wei_to_eth(t_wei)
        threshold_eth = K * P_eth  # _threshold_eth
        threshold_wei = int(threshold_eth * 1e18)

        if t_eth <= 0:
            # strategies.py:333-337
            action = "deploy_minimum"
        elif t_eth >= threshold_eth:
            # strategies.py:339-346, exact format string
            action = "skip"
            skip_reason = (
                f"predicted T={t_eth:.7f} ETH >= THRESHOLD={threshold_eth:.7f}, "
                "negative EV, skipping"
            )
        else:
            # strategies.py:348 → _resolve_per_block → _optimal_x_eth
            raw_total_eth = math.sqrt(K * P_eth * t_eth) - t_eth
            if raw_total_eth <= 0:
                # Float drift near the threshold boundary. Strategies.py
                # would proceed through _resolve_per_block and then clamp to
                # the minimum deploy; the indexer records this as the raw X*
                # value (possibly small/zero) and lets the verifier observe
                # any clamping at vault level via actual_deploy_wei (a future
                # field).
                x_star_wei = 0
            else:
                x_star_wei = int(raw_total_eth * 1e18)
            action = "deploy_optimum"

x_star_field = None if x_star_wei is None else str(x_star_wei)

# Block fields come pre-quoted from the caller ("null" or "\"0x...\"" / digits).
def raw_or_null(s: str):
    if s == "null":
        return None
    if s.startswith('"') and s.endswith('"'):
        return s[1:-1]
    return int(s)

block_number = raw_or_null(block_number_raw)
block_hash   = raw_or_null(block_hash_raw)

doc = {
    "schema_version": schema_version,
    "network": "base-mainnet",
    "chain_id": 8453,
    "agent": "nostradamus",
    "contracts": {
        "grid_mining": grid_mining,
        "nostradamus_vault": vault,
        "bean_token": bean_token,
    },
    "decision": {
        "round_id": round_id,
        "decided_at": decided_at,
        "block_number": block_number,
        "block_hash": block_hash,
        "inputs": {
            "bean_price_eth_wei": str(bean_price_eth_wei),
            "bean_price_eth": price_str if price_available else "",
            "T_wei": str(t_wei),
            "B": b_const_str,
            "fee_drag": fee_drag_str,
            "K_float": k_float_str,
            "threshold_wei": str(threshold_wei),
        },
        "output": {
            "action": action,
            "X_star_wei": x_star_field,
            # Phase 1: deploy_tx + actual_deploy_wei deferred to a later
            # indexer version that scans the vault's outbound receipts.
            "actual_deploy_wei": None,
            "deploy_tx": None,
            "skip_reason": skip_reason,
        },
    },
    "indexed_at": indexed_at,
    "signer_did": signer_did,
}

print(json.dumps(doc, indent=2, sort_keys=False))
PYEOF
    )

    if [ -n "${OUTPUT_PATH:-}" ]; then
        printf '%s\n' "$output" > "$OUTPUT_PATH"
        echo "Wrote decision for round ${target_round} to $OUTPUT_PATH" >&2
    else
        printf '%s\n' "$output"
    fi
}

main "$@"
