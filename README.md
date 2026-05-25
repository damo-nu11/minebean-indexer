# minebean-indexer

Bash indexer that reads on-chain state and events from the MineBean `GridMining` contract on Base and publishes signed audit logs to MineBean's Gitlawb repos. Four flows ship today:

- **commit-window** → [`minebean-rounds`](https://gitlawb.com/z6MkwVfgaAnuypajisEkJLkVbWPiPEBwceMkGutfXpEEYHKi/minebean-rounds): one window file every 5 minutes covering the last 5 settled rounds.
- **commit-nostradamus** → [`minebean-nostradamus`](https://gitlawb.com/z6MkwVfgaAnuypajisEkJLkVbWPiPEBwceMkGutfXpEEYHKi/minebean-nostradamus): one decision file per settled round, replaying the canonical closed-form EV math from `hermes-mine-bean/strategies.py` (`_nostradamus`).
- **commit-claims** → [`minebean-claims`](https://gitlawb.com/z6MkwVfgaAnuypajisEkJLkVbWPiPEBwceMkGutfXpEEYHKi/minebean-claims): one claim file per `ClaimedBEAN` event emitted by GridMining, with pseudonymized claimer and the full mined/roasted/fee/net breakdown.
- **commit-beanpots** → [`minebean-beanpots`](https://gitlawb.com/z6MkwVfgaAnuypajisEkJLkVbWPiPEBwceMkGutfXpEEYHKi/minebean-beanpots): one hit file per `RoundSettled` event where `beanpotAmount > 0`, covering both single-winner and split-pot scenarios.

All four flows are independent: separate workflows, separate concurrency groups, separate Gitlawb repos.

## How it works

Every cron tick (default every 5 minutes):

1. Read `currentRoundId` from the GridMining contract
2. Determine the last 5 fully-settled rounds
3. Call `rounds(roundId)` on the contract for each one
4. Compute a deterministic pseudonym for any beanpot winner
5. Compute a grid state hash from `getRoundDeployed(roundId)`
6. Build a window JSON file conforming to the schema in `minebean-rounds/SCHEMA.md`
7. Clone the Gitlawb repo, write the file, sign + push the commit
8. Exit cleanly. Next tick repeats.

## Architecture

Pure bash + Foundry `cast` + `git-remote-gitlawb`. No LLM in the loop. No third-party services beyond Gitlawb's public 3-node network and a Base RPC endpoint.

Scheduled via cron-job.org hitting GitHub's `workflow_dispatch` API every 5 minutes. Same trigger pattern used by `damo-nu11/aeon-minebean`.

## Cost

Zero ongoing operational cost at our scale. GitHub Actions free tier covers the runtime. Gitlawb public network is free. Public Base RPC is free.

## Required secrets (GitHub Actions)

Set under repo Settings → Secrets and variables → Actions:

| Secret | What it is |
|---|---|
| `GITLAWB_IDENTITY_PEM_B64` | Base64-encoded contents of `~/.gitlawb/identity.pem` |
| `GITLAWB_UCAN_JSON_B64` | Base64-encoded contents of `~/.gitlawb/ucan.json` |
| `GITLAWB_PSEUDONYM_SALT` | Random 32-byte hex string. Generated once, never rotated. Used by `commit-window` and `commit-claims`. |
| `GITLAWB_DID` | The DID that owns the MineBean Gitlawb repos (e.g. `did:key:z6Mk…`). |
| `GITLAWB_REPO_URL` | Gitlawb push URL for the rounds repo (e.g. `gitlawb://…/minebean-rounds`). Used by `commit-window`. |
| `GITLAWB_NOSTRADAMUS_REPO` | Gitlawb push URL for the nostradamus repo (e.g. `gitlawb://…/minebean-nostradamus`). Used by `commit-nostradamus`. |
| `GITLAWB_CLAIMS_REPO` | Gitlawb push URL for the claims repo (e.g. `gitlawb://…/minebean-claims`). Used by `commit-claims`. |
| `GITLAWB_BEANPOTS_REPO` | Gitlawb push URL for the beanpots repo (e.g. `gitlawb://…/minebean-beanpots`). Used by `commit-beanpots`. |
| `BASE_RPC_URL` | Base mainnet RPC endpoint. Public works (`https://mainnet.base.org`). |

## Manual trigger

```bash
gh workflow run commit-window.yml       --repo damo-nu11/minebean-indexer
gh workflow run commit-nostradamus.yml  --repo damo-nu11/minebean-indexer
gh workflow run commit-claims.yml       --repo damo-nu11/minebean-indexer
gh workflow run commit-beanpots.yml     --repo damo-nu11/minebean-indexer
```

Or via cron-job.org POSTing to (one entry per workflow):

```
https://api.github.com/repos/damo-nu11/minebean-indexer/actions/workflows/commit-window.yml/dispatches
https://api.github.com/repos/damo-nu11/minebean-indexer/actions/workflows/commit-nostradamus.yml/dispatches
https://api.github.com/repos/damo-nu11/minebean-indexer/actions/workflows/commit-claims.yml/dispatches
https://api.github.com/repos/damo-nu11/minebean-indexer/actions/workflows/commit-beanpots.yml/dispatches
```

## Local testing

```bash
# Install Foundry if you don't have it
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Install Gitlawb CLI
curl -fsSL https://gitlawb.com/install.sh | sh

# Set env
export BASE_RPC_URL=https://mainnet.base.org
export GITLAWB_PSEUDONYM_SALT="$(openssl rand -hex 32)"
export DRY_RUN=true

# Run window indexer once
bash scripts/run.sh

# Run nostradamus indexer once (no push)
OUTPUT_PATH=/tmp/nostradamus-decision.json bash scripts/fetch-nostradamus.sh
jq '.decision' /tmp/nostradamus-decision.json
```

`DRY_RUN=true` skips the git push step. The window JSON is written to `/tmp/minebean-indexer-window.json` for inspection. The nostradamus decision is written to `/tmp/nostradamus-decision.json`.

## Contracts (Base, chain 8453)

| Contract | Address |
|---|---|
| GridMining | `0x9632495bDb93FD6B0740Ab69cc6c71C9c01da4f0` |
| Bean (ERC20) | `0x5c72992b83E74c4D5200A8E8920fB946214a5A5D` |
| Nostradamus vault | `0x1098f65b0529E7E78cE8749621e3F0427b2a37f6` |

## License

MIT.
