# Mainnet readiness check (22–23 Nov 2026)

Verdict: **not ready for mainnet.** The contracts compile and pass their tests, but they have never run a real transaction, have had no independent audit, and several design and legal decisions are still open.

Arc Studio does not deploy to, sign for, or fund anything on mainnet. Any mainnet use must be reviewed, deployed and operated by you outside Arc Studio, from your own wallet.

## 1. Checked today (facts)

| Check | Result | Source |
|---|---|---|
| Arc mainnet chain ID in the app's registry | 5042 | `src/onchain-facts.ts` |
| USDC address on Arc mainnet equals the address hardcoded in the contracts (`0x3600…0000`) | Yes | registry and live read |
| USDC `decimals()` and `symbol()` on Arc mainnet | 6 and "USDC" | live read on Arc mainnet |
| `isBlacklisted(address)` exists on Arc mainnet USDC | Yes (returned false for the admin address) | live read |
| `authorizationState(address,bytes32)` (EIP-3009) exists | Yes | live read |
| Full test suite re-run | 131 passed, 0 failed (mock USDC, standard EVM) | `forge test` |
| Contracts use `selfdestruct`, `delegatecall`, `tx.origin`, `prevrandao` | None | source search |
| Admin address `0x223c…9c15` on mainnet | No code (a plain key, same address as on testnet) | live lookup |

## 2. Gaps that block mainnet

| # | Gap | Why it matters | What closes it |
|---|---|---|---|
| 1 | No independent audit | Internal reviews ran twice. The last fix (holdback shortfall) was tested but not re-reviewed, and the rule-based auditor reported nothing on about 600 lines of complex accounting, which is low confidence. | Independent professional audit of all four contracts. |
| 2 | Never exercised onchain | The testnet factory shows `groupCount` = 0. All tests use a mock USDC on a standard EVM. Real USDC behaviour (blocklist reverts, the 50,000-gas `isBlacklisted` call, Arc's native/ERC-20 duality, EIP-7708 events) is untested. | Fork tests against real Arc USDC state, then a full group lifecycle on testnet from the UI. |
| 3 | Single-key admin | The admin can pause new-group creation. A stolen key stops creation only, but it is still one key. | Move to a multisig before launch. Use a different key from the deployer. |
| 4 | Passport gate not usable | The attester in the deployed gate is a throwaway key generated in the sandbox. No attestation service exists. | New attester held in your own key management, plus a hardened attestation service, or launch with the gate off and caps instead. |
| 5 | Testnet-flavoured parameters | The factory floors were set for testing (1 to 1,000 USDC per installment, 365-day maximum, 30% minimum holdback, 1-hour minimum period). Contracts are immutable, so these cannot be changed later. | Choose floors and caps from a loss budget you set, then deploy a new factory. |
| 6 | Open product decisions | Jurisdiction, loss cap per member, interest rate and its legal status, who the organiser is in law, and whether the registry ban is permanent are all undecided. | Owner decisions and a written legal opinion for the real jurisdiction. |
| 7 | Features cut from v0 | Interest, guarantors, wallet recovery, member replacement, group deferral, wind-down and clearing a registry ban by repaying are not built. | Decide which are required for a pilot; each needs its own review. |
| 8 | Frontend is testnet-only | The app is fixed to Arc Testnet (`CHAIN_ID`, the wagmi config, `VITE_` addresses). The Netlify site sits behind Netlify login. | Add Arc mainnet as a configured chain with your own deployment addresses, and open site access deliberately. |
| 9 | No operations | No monitoring or alerts, no incident process, no support or dispute path, and nobody is assigned to call the permissionless `sync`, `resolveLate` and `finalize`. | Run a keeper and watcher, write an incident plan, publish a support path. |
| 10 | Known model difference | Totals match the simulation, but the per-victim split differs because defaults are declared after the grace and cure windows. | Decide whether this behaviour is acceptable and explain it to members. |
| 11 | Mainnet gas for users | Users need USDC on mainnet for gas. I could not verify how a new mainnet user gets gas. | Confirm funding path with Circle documentation before any pilot. |

## 3. Risks that stay even after the gaps are closed

- A bug in the immutable group contract cannot be fixed. It can only be avoided in new groups by deploying a new factory.
- The USDC issuer can blocklist the group contract or a member. Funds in a blocked contract would be stuck, and nothing in the contracts can undo that.
- Arc validators are a permissioned set, so network-level pause or censorship is possible.
- Collusion between real people, coercion and unreported outside debts cannot be solved onchain.

## 4. Suggested order before any mainnet step

1. Fork-test against real Arc USDC and run a full lifecycle on testnet through the UI.
2. Decide the open product and legal questions, with a written legal opinion for your jurisdiction.
3. Fix the parameter floors and caps from a loss budget. Keep the first pilot very small.
4. Commission an independent audit and fix its findings.
5. Set up a multisig admin, a hardened attester or gate-off launch, monitoring and a keeper.
6. Only then deploy from your own wallet and operate it yourself.
