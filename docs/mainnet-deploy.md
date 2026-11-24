# Deploying to Arc mainnet (you run this, outside Arc Studio)

Arc Studio does not deploy to, sign for, or fund anything on mainnet. These steps run on your machine with your key. Real funds are involved and transactions cannot be undone. Read `docs/mainnet-readiness.md` first and complete your own review.

## Before you run anything
1. Decide and write down the immutable factory floors: minimum holdback, minimum deposit, installment range, maximum duration. The script has no defaults.
2. Use a multisig as `ADMIN` (it can only pause or unpause creating new groups). The testnet admin is a single key.
3. Do not reuse the testnet Passport attester key. Leave the gate off, or deploy a gate trusting an attester you control and have a service for.
4. Get an independent audit and any legal review your jurisdiction needs.

## Run
```bash
export PRIVATE_KEY=...        # your deployer key, set in your shell only
export ADMIN=0x...            # multisig
export MIN_PHI_BPS=... MIN_DEPOSIT_BPS=... MIN_C=... MAX_C=... MAX_DURATION=...
# optional: export GATE=0x...   or   export ATTESTER=0x...
bash scripts/deploy-mainnet.sh
```
The script checks chain id 5042, asks you to type DEPLOY, deploys the group implementation, the optional gate and the factory, then reads the key values back from chain so you can compare them with what you intended.

## Point the app at it
Add the printed `VITE_ROSCA_*` lines to `.env`, run `bun run build`, and host `dist/`. Testnet stays the default when `VITE_ROSCA_NETWORK` is not `mainnet`.

## Open items
See "Blockers" in `docs/mainnet-readiness.md`: audit, multisig admin, monitoring and keepers, legal review, mainnet gas for new users.
