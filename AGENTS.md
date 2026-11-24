# [App Name]

> Built with Arc Studio - money-powered apps in minutes

This is the **project memory** - what Arc Studio remembers about building this app. It helps future agents (or humans) understand and extend the project.

---

## What This App Does

[Brief description of what the app does and its primary use case]

## Tech Stack

- Frontend: React 18, Vite, TypeScript, Tailwind CSS
- Web3: wagmi v2, viem v2, ConnectKit
- Contracts: Solidity 0.8.28 + Foundry. Sources in `contracts/`, unit tests in `contracts/test/*.t.sol`. Build with `bun run contracts:build` (`forge build`), test with `bun run contracts:test` (`forge test`).
- Wallet: injected (MetaMask, etc.)
- Chain: Arc Testnet (Chain ID: 5042002, imported from `viem/chains`)
- Token: USDC (6 decimals) (Address: 0x3600000000000000000000000000000000000000, Chain: Arc Testnet)
- Toasts: Sonner

## Key Files

- `src/App.tsx` - Main application logic
- `src/components/` - UI components
- `src/config.ts` - wagmi config (chains, connectors, transports)

## Share links

- Starter apps already ship `getShareBase`, `buildShareLink` and `installShareSync` in `src/lib/share.ts`; import them instead of rewriting them.
- Keep shareable state in the URL path or query, not in the `#fragment`.
- Never put a secret (private key, claim secret, seed phrase, session token, API key) in the URL path or query, encoded or not: every in-app path and query is mirrored to the visitor's studio.arc.io address bar and browser history and reaches servers. A bearer claim secret goes only in the `#fragment` appended to the share link (`` `${await buildShareLink('/claim')}#${secret}` ``) and is read from `location.hash` on load. A link to the app's own share URL shown inside the app must be copy-only or open in a new tab with `target="_blank" rel="noopener noreferrer"`.
- Build every link a user copies or sends with `buildShareLink()` from `src/lib/share.ts`.
- Keep the `installShareSync()` call in `src/main.tsx` when editing it; it keeps the Studio address bar in step with in-app navigation.
- Navigate inside the app with relative links.

## To Run

```bash
bun install
bun run dev
```

## ROSCA design review (docs/rosca-review-*.md)
- Admin model: Minimal-admin chosen by owner. Admin address (EOA, single key, no code on Arc Testnet as of 2026-11-22): 0x223c2D5Af8120cAb3c68b5587feC7c8649Ce9c15. Powers: pause/unpause new-group creation only. No contracts written or deployed yet.
- Sybil gate: owner chose Human Passport (human.tech), score must be strictly > 20, via off-chain attestor signing EIP-712 (no Passport onchain decoder on Arc). Needs PASSPORT_API_KEY and PASSPORT_SCORER_ID in .env (user adds; never paste in chat). Attester key must differ from admin address. See docs/rosca-review-7-sybil-integrations.md section 6.
- Owner decisions (2026-11-22): on-chain DefaultRegistry (called "blacklist" by owner; blocks joining new groups only, never touches claims/pay) and interest paid by early recipients to late-slot members (not insurance; see docs/rosca-review-9-interest-and-default-registry.md). Open: rate r and r_max, upfront vs per-round, permanent vs clearable, jurisdiction.

## Deployed on Arc Testnet (2026-11-22)

- GroupFactory: 0xf3d0ba6e5de0f7e970404fc3dfc818f8b4d5e756 (admin 0x223c2D5Af8120cAb3c68b5587feC7c8649Ce9c15, floors: phi >= 30%, deposit >= 100% of installment, c 1 to 1000 USDC, max duration 365 days)
- RoscaGroup implementation (cloned per group): 0x0d518ce733482df24676720db1264c301f2344bb
- PassportGate: 0x507a82d2c7d7e3294047fd96e08465fa32166fa4 (attester 0xB2246030667E5a3Da5cC24e299F9B7d76f196C73, testnet key in .env as PASSPORT_ATTESTER_PRIVATE_KEY; replace before real use)
- DefaultRegistry (created by the factory): 0x192511BEed8A0De5761CB786bbaabCFD0ba46233
- Frontend: https://darling-profiterole-23483a.netlify.app (Netlify; site access control currently requires Netlify login)
- Frontend reads addresses from VITE_ROSCA_* in .env. The UI creates groups with useGate=false (no attestation service yet).
- Review status: tests 131 pass; the holdback-bypass fix was tested but not re-reviewed after the fix (audit round cap reached). Interest, guarantors, wallet recovery, member replacement and repay-to-clear are deferred.

## Mainnet support (added 2026-11-23)
- The app can target Arc mainnet with `VITE_ROSCA_NETWORK=mainnet` plus `VITE_ROSCA_MAINNET_*` addresses. Without a mainnet factory address it shows a setup screen.
- Mainnet contracts are NOT deployed. The owner deploys them from their own machine with `scripts/deploy-mainnet.sh` (see `docs/mainnet-deploy.md`). Arc Studio does not deploy to or transact on mainnet.
- Deployment floors are immutable and have no defaults in the script on purpose.

## Arc mainnet deployment (user-deployed 2026-11-24, chain 5042)
- RoscaGroup implementation: 0x2D48FB08e938c272fb86bcF472e31010a61CBE05 (tx 0xe1bce2ce...791f69), runtime matches the tested build
- GroupFactory: 0xeb28adf57c8b0f7e4ad381b16f69c66871cb59d6 (tx 0x06600505...d204d0), registry created by factory: 0xf7369f5b7b29456593a0258bdc3ddaf51ba075af
- Constructor values read back from chain: admin 0x223c...9c15 (single EOA), gate none, minPhiBps 5000, minDepositBps 10000, minC 1 USDC, maxC 10000 USDC, maxDuration 31536000 s
- Two stray empty library deployments from Remix (0xB9D9...dB85, 0xDA3A...4276): harmless, ignore.
- Not set: VITE_ROSCA_NETWORK stays testnet until the owner asks for a mainnet build.
