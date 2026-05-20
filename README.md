# minebean-indexer

Bash indexer that reads closed rounds from the MineBean `GridMining` contract on Base and publishes a 5-minute audit window to the [`minebean-rounds`](https://gitlawb.com/z6MkwVfgaAnuypajisEkJLkVbWPiPEBwceMkGutfXpEEYHKi/minebean-rounds) repo on Gitlawb.

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
| `GITLAWB_PSEUDONYM_SALT` | Random 32-byte hex string. Generated once, never rotated. |
| `GITLAWB_DID` | The DID that owns the `minebean-rounds` repo (e.g. `did:key:z6Mk…`). |
| `GITLAWB_REPO_URL` | Gitlawb push URL for the rounds repo (e.g. `gitlawb://…/minebean-rounds`). |
| `BASE_RPC_URL` | Base mainnet RPC endpoint. Public works (`https://mainnet.base.org`). |

## Manual trigger

```bash
gh workflow run commit-window.yml --repo damo-nu11/minebean-indexer
```

Or via cron-job.org POSTing to:

```
https://api.github.com/repos/damo-nu11/minebean-indexer/actions/workflows/commit-window.yml/dispatches
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

# Run once
bash scripts/run.sh
```

`DRY_RUN=true` skips the git push step. The window JSON is written to `/tmp/minebean-indexer-window.json` for inspection.

## Contracts (Base, chain 8453)

| Contract | Address |
|---|---|
| GridMining | `0x9632495bDb93FD6B0740Ab69cc6c71C9c01da4f0` |
| Bean (ERC20) | `0x5c72992b83E74c4D5200A8E8920fB946214a5A5D` |

## License

MIT.
