# Rosca Circle

A rotating savings circle (ROSCA) for USDC on Arc Testnet. A small group agrees on a fixed order, everyone pays an installment each round, and one member takes the pot each round. Part of each pot is held back as collateral and a deposit covers a missed installment. This is a test version with no real value, and nobody guarantees the principal.

Built with [Arc Studio](https://studio.arc.io)

## Tech stack

- React, Vite, TypeScript, Tailwind CSS
- wagmi, viem, ConnectKit
- Solidity 0.8.28 and Foundry (contracts in `contracts/`, tests in `contracts/test/`)

## Development

Prerequisites: [Bun](https://bun.sh) and [Foundry](https://book.getfoundry.sh).

```bash
bun install
bun run dev          # start the app
bun run build        # production build (vite)
bun run check        # lint and typecheck
bun run contracts:build
bun run contracts:test
```

### Environment variables

Public (read by the browser app):

- `VITE_ROSCA_FACTORY_ADDRESS`: group factory contract on Arc Testnet
- `VITE_ROSCA_GROUP_IMPL_ADDRESS`: group implementation the factory clones
- `VITE_ROSCA_GATE_ADDRESS`: Passport attestation verifier
- `VITE_ROSCA_REGISTRY_ADDRESS`: default registry created by the factory
- `VITE_ROSCA_ADMIN_ADDRESS`: the address that can pause creation of new groups
- `VITE_ROSCA_NETWORK`: `testnet` (default) or `mainnet`. Mainnet needs the four variables below
- `VITE_ROSCA_MAINNET_FACTORY_ADDRESS`, `VITE_ROSCA_MAINNET_REGISTRY_ADDRESS`, `VITE_ROSCA_MAINNET_GATE_ADDRESS`, `VITE_ROSCA_MAINNET_ADMIN_ADDRESS`: contracts you deployed yourself on Arc mainnet (see `docs/mainnet-deploy.md`)

Server side only (not used by the browser app):

- `PASSPORT_ATTESTER_PRIVATE_KEY`: testnet signing key for Passport attestations. Keep it secret and replace it before any real use.
- `PASSPORT_API_KEY`, `PASSPORT_SCORER_ID`: needed only once the Passport attestation service is built

## Not included yet

Interest between members, guarantors, wallet recovery, member replacement and repaying a default to clear the registry are not part of this version.
