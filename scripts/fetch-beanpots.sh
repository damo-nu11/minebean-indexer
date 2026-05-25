#!/usr/bin/env bash
# fetch-beanpots.sh
#
# Scans the last LOOKBACK_BLOCKS of Base mainnet for RoundSettled events
# emitted by the MineBean GridMining contract, filters for the subset that
# triggered a beanpot payout (beanpotAmount > 0), decodes each, and emits a
# JSON array of beanpot hit records ready for commit-beanpots.sh.
#
# Event signature:
#   RoundSettled(
#     uint64  indexed roundId,
#     uint8   winningBlock,
#     address topMiner,
#     uint256 totalWinnings,
#     uint256 topMinerReward,
#     uint256 beanpotAmount,
#     bool    isSplit,
#     uint256 topMinerSeed,
#     uint256 winnersDeployed
#   )
#
# Decoding plan:
#   topics[0] = keccak256(canonical signature) — cast handles this
#   topics[1] = roundId, 32-byte left-padded uint64
#   data      = 8 fields ABI-encoded:
#               winningBlock(uint8, right-padded in 32 bytes),
#               topMiner(address, left-padded in 32 bytes),
#               totalWinnings(uint256),
#               topMinerReward(uint256),
#               beanpotAmount(uint256),
#               isSplit(bool, right-padded in 32 bytes),
#               topMinerSeed(uint256),
#               winnersDeployed(uint256)
#   Each field occupies one 32-byte slot in `data` (no dynamic types in this
#   event, so this is the standard non-indexed packing).
#
# Required env:
#   BASE_RPC_URL
#   GITLAWB_PSEUDONYM_SALT   hex (matches rounds + claims indexers)
# Optional env:
#   LOOKBACK_BLOCKS          default 300 (~10 min on Base @ ~2s blocks)
#   OUTPUT_PATH              where to write the JSON array (else stdout)

set -euo pipefail

: "${BASE_RPC_URL:?BASE_RPC_URL is required}"
: "${GITLAWB_PSEUDONYM_SALT:?GITLAWB_PSEUDONYM_SALT is required}"

GRID_MINING="0x9632495bDb93FD6B0740Ab69cc6c71C9c01da4f0"
BEAN_TOKEN="0x5c72992b83E74c4D5200A8E8920fB946214a5A5D"
LOOKBACK_BLOCKS="${LOOKBACK_BLOCKS:-300}"
SCHEMA_VERSION="0.1.0"
SIGNER_DID="${GITLAWB_DID:-did:key:z6MkwVfgaAnuypajisEkJLkVbWPiPEBwceMkGutfXpEEYHKi}"

# Tmp file for the raw cast logs payload. Created inside main() but declared
# at script scope so the EXIT trap can reference it under `set -u` without
# tripping on an unset variable after main() returns.
RAW_LOGS_PATH=""
trap '[ -n "$RAW_LOGS_PATH" ] && rm -f "$RAW_LOGS_PATH"' EXIT

first_tok() {
    awk '{print $1}'
}

is_uint_dec() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

now_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

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

# Compute grid_state_hash by replaying the same scheme as fetch-window.sh:
# raw text output of `cast call getRoundDeployed(roundId)` hex-encoded then
# keccak256'd. Tied to cast's text representation, but identical for both
# indexers so the hashes match between minebean-rounds and minebean-beanpots
# for the same round.
compute_grid_state_hash() {
    local round_id="$1"
    local grid_deployed
    if ! grid_deployed=$(cast call "$GRID_MINING" \
        "getRoundDeployed(uint64)(uint256[25])" \
        "$round_id" \
        --rpc-url "$BASE_RPC_URL" 2>&1); then
        echo "ERROR: cast call getRoundDeployed($round_id) failed: $grid_deployed" >&2
        return 1
    fi
    if [ -z "$grid_deployed" ]; then
        echo "ERROR: empty getRoundDeployed output for round $round_id" >&2
        return 1
    fi
    local packed
    packed=$(echo -n "$grid_deployed" | xxd -p | tr -d '\n')
    if [ -z "$packed" ]; then
        echo "ERROR: empty hex pack for round $round_id" >&2
        return 1
    fi
    local hash
    if ! hash=$(cast keccak "0x${packed}" 2>&1); then
        echo "ERROR: cast keccak failed for round $round_id: $hash" >&2
        return 1
    fi
    echo "$hash" | first_tok
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

    echo "Scanning blocks ${from_block}..${tip} for RoundSettled events" >&2

    local raw_logs
    if ! raw_logs=$(cast logs \
        --from-block "$from_block" --to-block "$tip" \
        --address "$GRID_MINING" \
        "RoundSettled(uint64,uint8,address,uint256,uint256,uint256,bool,uint256,uint256)" \
        --rpc-url "$BASE_RPC_URL" \
        --json 2>&1); then
        echo "ERROR: cast logs failed: $raw_logs" >&2
        exit 1
    fi

    local log_count
    log_count=$(printf '%s' "$raw_logs" | jq 'length')
    echo "Found ${log_count} RoundSettled event(s) in window" >&2

    # First pass in Python: decode each log, keep only beanpot hits, and emit
    # a pruned JSON array with the on-chain fields plus the round_id (for the
    # subsequent grid_state_hash lookup). Pseudonym is computed in Python.
    # raw_logs is potentially large (thousands of RoundSettled events over a
    # multi-day window), so write it to a temp file and pass the PATH via env
    # var to avoid hitting ARG_MAX. The salt stays in an env var.
    # The tmp file path is held in the script-scope RAW_LOGS_PATH variable
    # so the EXIT trap (registered at script scope, below the constants) can
    # clean it up without tripping `set -u` after main() returns.
    RAW_LOGS_PATH=$(mktemp -t beanpots-raw.XXXXXX)
    printf '%s' "$raw_logs" > "$RAW_LOGS_PATH"

    local pruned
    pruned=$(
        BEANPOTS_RAW_LOGS_PATH="$RAW_LOGS_PATH" \
        BEANPOTS_PSEUDONYM_SALT="$GITLAWB_PSEUDONYM_SALT" \
        python3 - <<'PYEOF'
import json
import os
import sys

with open(os.environ["BEANPOTS_RAW_LOGS_PATH"]) as f:
    raw_logs = json.load(f)
salt_hex = os.environ["BEANPOTS_PSEUDONYM_SALT"].removeprefix("0x")

def keccak(b: bytes) -> str:
    try:
        from Crypto.Hash import keccak as keccak_mod
        k = keccak_mod.new(digest_bits=256)
        k.update(b)
        return k.hexdigest()
    except ImportError:
        pass
    import subprocess
    res = subprocess.run(
        ["cast", "keccak", "0x" + b.hex()],
        capture_output=True, text=True, check=True,
    )
    return res.stdout.strip().split()[0].removeprefix("0x")

def pseudonym_for(addr_hex: str):
    if not addr_hex or addr_hex.lower() == "0x" + "00" * 20:
        return None
    addr_clean = addr_hex.lower().removeprefix("0x")
    if len(addr_clean) != 40:
        return None
    combined = bytes.fromhex(addr_clean + salt_hex)
    return keccak(combined)[:8]

def hex_to_int(h):
    return int(h, 16) if isinstance(h, str) else int(h)

pruned_records = []
seen_round_ids = set()

for log in raw_logs:
    topics = log["topics"]
    data   = log["data"].removeprefix("0x")
    if len(topics) < 2:
        print(f"WARN: RoundSettled log missing roundId topic, skipping", file=sys.stderr)
        continue
    # topics[1] is the 32-byte left-padded uint64 roundId
    round_id_topic = topics[1].lower().removeprefix("0x")
    if len(round_id_topic) != 64:
        print(f"WARN: malformed roundId topic, skipping", file=sys.stderr)
        continue
    round_id = int(round_id_topic, 16)

    # data is 9 ABI-encoded fields, each padded into one 32-byte slot:
    #   0: winningBlock (uint8, right-padded)
    #   1: topMiner (address, left-padded)
    #   2: totalWinnings (uint256)
    #   3: topMinerReward (uint256)
    #   4: beanpotAmount (uint256)
    #   5: isSplit (bool, right-padded)
    #   6: topMinerSeed (uint256)
    #   7: winnersDeployed (uint256)
    # Wait: that's 8 fields, matching the 8 non-indexed event params. The
    # indexed roundId lives in topics[1] not data.
    if len(data) != 8 * 64:
        print(
            f"WARN: malformed RoundSettled data len={len(data)} for round {round_id}, skipping",
            file=sys.stderr,
        )
        continue

    winning_block      = int(data[0:64],      16)
    # address occupies the right-most 20 bytes of slot 1
    top_miner          = "0x" + data[64+24:64+64]
    total_winnings_wei = int(data[128:192],   16)
    top_miner_reward   = int(data[192:256],   16)
    beanpot_amount_wei = int(data[256:320],   16)
    is_split           = int(data[320:384],   16) != 0
    top_miner_seed     = int(data[384:448],   16)
    winners_deployed   = int(data[448:512],   16)

    # Filter: only emit RoundSettled events that triggered a beanpot. Plain
    # settlements without a beanpot payout are out of scope for this repo.
    if beanpot_amount_wei == 0:
        continue

    # SCHEMA invariant: round_id is unique. Two hits with the same round id
    # is a contract-level impossibility; if observed, halt.
    if round_id in seen_round_ids:
        print(f"ERROR: duplicate RoundSettled with beanpot for round {round_id}", file=sys.stderr)
        sys.exit(1)
    seen_round_ids.add(round_id)

    # top_miner_pseudonym handling. This is the pseudonym of the topMiner
    # field from RoundSettled (the recipient of the round's topMinerReward),
    # NOT a "beanpot winner" — the beanpot itself is always distributed
    # proportionally across all winners on the winning block.
    #   - is_split == true: contract emits topMiner == 0x0 because no single
    #     recipient exists for the topMinerReward (it's split proportionally
    #     across tied winners). Emit top_miner_pseudonym = null.
    #   - is_split == false: derive pseudonym normally. If it still comes
    #     back null (e.g. malformed address), that's a real anomaly and we
    #     halt rather than silently dropping the hit.
    if is_split:
        top_miner_pseudo = None
    else:
        top_miner_pseudo = pseudonym_for(top_miner)
        if top_miner_pseudo is None:
            print(
                f"ERROR: non-split RoundSettled for round {round_id} has unusable topMiner {top_miner}, halting",
                file=sys.stderr,
            )
            sys.exit(1)

    block_hash = log.get("blockHash", "").lower()
    if not block_hash.startswith("0x") or len(block_hash) != 66:
        print(f"ERROR: malformed blockHash for round {round_id}: {block_hash}", file=sys.stderr)
        sys.exit(1)

    block_ts_raw = log.get("blockTimestamp")
    if block_ts_raw is None:
        print(f"ERROR: blockTimestamp missing for round {round_id}", file=sys.stderr)
        sys.exit(1)

    tx_hash = log["transactionHash"].lower()

    pruned_records.append({
        "round_id":            round_id,
        "settlement_tx":       tx_hash,
        "settlement_block":    hex_to_int(log["blockNumber"]),
        "block_ts":            hex_to_int(block_ts_raw),
        "winning_block_index": winning_block,
        "beanpot_amount_wei":  str(beanpot_amount_wei),
        "is_split":            is_split,
        "top_miner_pseudonym": top_miner_pseudo,
    })

print(json.dumps(pruned_records))
PYEOF
    )

    local pruned_count
    pruned_count=$(printf '%s' "$pruned" | jq 'length')
    echo "Found ${pruned_count} beanpot hit(s) in window (after filtering)" >&2

    # Enrich each pruned record with grid_state_hash via a cast call. This is
    # done in shell because cast invocation per round is cleaner than from
    # within Python; the count is bounded (beanpots are rare) so the extra
    # subprocesses are not a hot path.
    local enriched="[]"
    if [ "$pruned_count" -gt 0 ]; then
        local i
        for i in $(seq 0 $((pruned_count - 1))); do
            local rid
            rid=$(printf '%s' "$pruned" | jq -r ".[$i].round_id")
            if ! is_uint_dec "$rid"; then
                echo "ERROR: malformed round_id in pruned record $i" >&2
                exit 1
            fi
            local gsh
            if ! gsh=$(compute_grid_state_hash "$rid"); then
                echo "ERROR: failed to compute grid_state_hash for round $rid" >&2
                exit 1
            fi
            if [[ ! "$gsh" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
                echo "ERROR: malformed grid_state_hash for round $rid: $gsh" >&2
                exit 1
            fi
            enriched=$(printf '%s' "$enriched" | \
                jq --argjson rec "$(printf '%s' "$pruned" | jq -c ".[$i]")" \
                   --arg gsh "$gsh" \
                   '. + [($rec + {grid_state_hash: $gsh})]')
        done
    fi

    # Final assembly in Python. Inputs via env vars only.
    local output
    output=$(
        BEANPOTS_ENRICHED="$enriched" \
        BEANPOTS_GRID_MINING="$GRID_MINING" \
        BEANPOTS_BEAN_TOKEN="$BEAN_TOKEN" \
        BEANPOTS_SCHEMA_VERSION="$SCHEMA_VERSION" \
        BEANPOTS_SIGNER_DID="$SIGNER_DID" \
        BEANPOTS_INDEXED_AT="$(now_iso)" \
        python3 - <<'PYEOF'
import json
import os
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP

enriched      = json.loads(os.environ["BEANPOTS_ENRICHED"])
grid_mining   = os.environ["BEANPOTS_GRID_MINING"]
bean_token    = os.environ["BEANPOTS_BEAN_TOKEN"]
schema_version = os.environ["BEANPOTS_SCHEMA_VERSION"]
signer_did    = os.environ["BEANPOTS_SIGNER_DID"]
indexed_at    = os.environ["BEANPOTS_INDEXED_AT"]

def wei_to_bean_str(wei: int) -> str:
    d = Decimal(wei) / Decimal(10 ** 18)
    q = d.quantize(Decimal("0.0001"), rounding=ROUND_HALF_UP)
    return f"{q:.4f}"

hits_out = []
for rec in enriched:
    closed_at = datetime.fromtimestamp(
        rec["block_ts"], tz=timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    beanpot_wei = int(rec["beanpot_amount_wei"])
    doc = {
        "schema_version": schema_version,
        "network": "base-mainnet",
        "chain_id": 8453,
        "type": "beanpot_hit",
        "contracts": {
            "grid_mining": grid_mining,
            "bean_token": bean_token,
        },
        "hit": {
            "round_id":            rec["round_id"],
            "settlement_tx":       rec["settlement_tx"],
            "settlement_block":    rec["settlement_block"],
            "closed_at":           closed_at,
            "winning_block_index": rec["winning_block_index"],
            "beanpot_amount_wei":  str(beanpot_wei),
            "beanpot_amount_bean": wei_to_bean_str(beanpot_wei),
            "is_split":            rec["is_split"],
            "top_miner_pseudonym": rec["top_miner_pseudonym"],
            "grid_state_hash":     rec["grid_state_hash"],
        },
        "indexed_at": indexed_at,
        "signer_did": signer_did,
    }
    hits_out.append(doc)

print(json.dumps(hits_out, indent=2, sort_keys=False))
PYEOF
    )

    if [ -n "${OUTPUT_PATH:-}" ]; then
        printf '%s\n' "$output" > "$OUTPUT_PATH"
        local n
        n=$(printf '%s' "$output" | jq 'length')
        echo "Wrote ${n} beanpot hit record(s) to $OUTPUT_PATH" >&2
    else
        printf '%s\n' "$output"
    fi
}

main "$@"
