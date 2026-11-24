# ROSCA v0: implementation spec for the contracts (Arc Testnet)

Source of truth for the Solidity. Background and rationale: `docs/rosca-review-1` to `rosca-review-10` (read sections 3, 5, 6, 8, 9, 10 as needed). Where this file is stricter or simpler, THIS file wins. Testnet only: no real value.

Solc 0.8.28, evm cancun, OpenZeppelin 5.6.1 (`@openzeppelin/contracts/`). Files (filename = contract name, all under `/home/user/app/contracts/`): `IRosca.sol`, `DefaultRegistry.sol`, `PassportGate.sol`, `RoscaGroup.sol`, `GroupFactory.sol`. Custom errors, NatSpec on public functions, events for every state change. No `selfdestruct`, no `delegatecall` (except OZ Clones' own minimal proxy), no `receive`/payable functions, no admin power over group funds.

## 0. Deferred to v1 (do NOT implement, but leave no half-built hooks)

Interest between members (needs its own factory version), vouching/guarantors, wallet migration with guardians, member replacement, unanimous deferral, wind-down state (groups simply continue after a default), repay-to-clear registry entries (v0: a registry entry with unrecovered > 0 is permanent; unrecovered == 0 is auto-cleared), R-day deposit replenishment window (v0: deposit just must cover the missed amount; replenish via `topUpDeposit`).

## 1. Constants

`USDC = 0x3600000000000000000000000000000000000000` (6 decimals, fixed, NOT a parameter). `BPS = 10_000`. `DECLARE_BOUNTY = 50_000` (0.05 USDC). `RESERVE_EVENT_CAP_BPS = 5_000`. `MIN_SCORE_FLOOR_MILLI = 20_000` (a score must be STRICTLY greater). Use `SafeERC20`. All money in 6-decimal USDC units. Never read `address(this).balance`, never use `balanceOf` equality for logic.

## 2. IRosca.sol

```
struct Terms {
  uint8   n;               // members == rounds, 4..10
  uint256 c;               // principal installment (USDC units)
  uint16  phiBps;          // holdback fraction of remaining obligation
  uint256 d;               // deposit per member
  uint256 rho;             // reserve contribution per installment (may be 0)
  uint64  startTime;       // round 1 due time
  uint64  period;          // seconds between rounds
  uint64  grace;           // seconds after due, no penalty
  uint64  cure;            // seconds after grace; after it, resolveLate is allowed
  uint64  acceptDeadline;  // <= startTime
  bool    useGate;         // require Passport attestation for gated slots
  uint32  minScoreMilli;   // 0 when !useGate; else >= MIN_SCORE_FLOOR_MILLI
  uint256 ungatedCap;      // E, USDC units, used only if useGate
  address[] members;       // length n; slot = index + 1
}
interface IDefaultRegistry { function record(address wallet, address group, uint256 unrecovered, bool issuerBlocked) external; function isBanned(address wallet) external view returns (bool); }
interface IPassportGate { function verify(address wallet, bytes32 termsHash, uint32 scoreMilli, uint64 expiresAt, uint256 nonce, bytes calldata sig) external view returns (bool); }
interface IUSDCBlacklist { function isBlacklisted(address) external view returns (bool); }
struct Attestation { uint32 scoreMilli; uint64 expiresAt; uint256 nonce; bytes sig; }
```

## 3. DefaultRegistry

`constructor(address factory_)` (immutable factory). `record(...)` only callable if `IGroupFactory(factory).isGroup(msg.sender)`; stores `defaultCount[wallet]++`, `openUnrecovered[wallet] += unrecovered`; emits `DefaultRecorded(wallet, group, unrecovered, issuerBlocked)`. `isBanned(w)` = `openUnrecovered[w] > 0 && !issuerBlockedOnly` where entries with `issuerBlocked == true` add to `blockedCount` and never to `openUnrecovered`. Append-only, no owner, no delete.

## 4. PassportGate

`constructor(address attester_)`, immutable `attester`, EIP-712 domain ("RoscaPassportGate", "1"), via OZ `EIP712` + `ECDSA`. Typed data `HumanAttestation(address wallet,bytes32 termsHash,uint32 scoreMilli,uint64 expiresAt,uint256 nonce)`. `verify(...)` view: returns true iff recovered signer == `attester`, `expiresAt >= block.timestamp`, `scoreMilli > MIN_SCORE_FLOOR_MILLI`. Never reverts for a bad signature (returns false; use `ECDSA.tryRecover`). No state, no owner. (The group enforces `scoreMilli > terms.minScoreMilli` and replay protection.)

## 5. RoscaGroup (one per group, EIP-1167 clone, immutable logic)

Implementation contract: constructor calls `_disableInitializers()`. `initialize(Terms calldata t, address registry_, address gate_, address creator_)` once (OZ `Initializable`), called by the factory in the same tx as the clone. State: `Recruiting, Locked, Active, Closed, Cancelled`.

### 5.1 Derived values

`inst = c + rho` (full installment). `due(t) = startTime + (t-1)*period` for round `t` in 1..n. `recipient(t) = members[t-1]`. `hbAtReceipt(t) = ceil(phiBps * c * (n - t) / BPS)`. `relPerInst = ceil(phiBps * c / BPS)`. `termsHash = keccak256(abi.encode(block.chainid, address(this), t))` computed in `initialize`, stored, public.

Gating (only when `useGate`): `exposure(k) = max(0, ((BPS - phiBps) * c * (n - k)) / BPS - d)`. Mark slot k `needsAttestation` if `exposure(k) > ungatedCap`; then, among unmarked slots, while `sum(exposure of unmarked) > ungatedCap`, mark the unmarked slot with the largest exposure (lowest k on ties). Store `bool[] needsAtt`. Public view `requiresAttestation(slot)`.

### 5.2 Member state (arrays of length n, index = slot-1)

`status` (None, Accepted, Active, Defaulted), `deposit`, `holdback`, `claimable`, `rhoPaidTotal`, `depositUses` (uint8). Per round, per member: `paidC[t][i]`, `paidRho[t][i]` (mappings or fixed arrays). Group-level: `reserve`, `coveragePool`, `nextRound` (first unsettled round, starts at 1), `acceptedCount`, `roundSettled[t]`.

### 5.3 Recruiting and start

- `accept(Attestation calldata att)`: state Recruiting and `block.timestamp <= acceptDeadline`; caller must be `members[i]` with `status None`; `IDefaultRegistry(registry).isBanned(caller)` must be false; if `useGate && needsAtt[i]`: `gate != address(0)`, `att.scoreMilli > terms.minScoreMilli`, nonce not used (`usedNonce[keccak256(caller, nonce)]`), and `IPassportGate(gate).verify(caller, termsHash, att.scoreMilli, att.expiresAt, att.nonce, att.sig)` true; mark nonce used. Pull `d` USDC from caller (`safeTransferFrom`, measure received via balance delta and require `>= d`). `deposit[i] = d`, `status Accepted`, `acceptedCount++`; when it reaches n: state Locked, emit Locked.
- `withdraw()` (accepted member): in Recruiting: refund deposit to `claimable`, status None, count--. In Locked: state becomes Cancelled and EVERY accepted member's deposit goes to `claimable` (loop n). In Active: revert.
- `cancel()` anyone: if Recruiting and `now > acceptDeadline`, or Locked and `now >= startTime + period` (never started): Cancelled, refund all deposits to `claimable`.
- `_sync()` (internal, run at the start of every state-changing external function except `claim`): if Locked and `now >= startTime` -> Active (all members Accepted become Active); if Recruiting and `now >= startTime` -> Cancelled with refunds; then auto-settle rounds: `while nextRound <= n && roundReady(nextRound)` call `_settleRound(nextRound)` (at most n iterations).

### 5.4 Paying

- `pay(uint8 t, address member, uint256 amount)`: anyone pays for `member` from `msg.sender` (`safeTransferFrom`); state Active; `1 <= t <= n`; member Active; member != `recipient(t)`; `block.timestamp >= due(t)`; amount capped at remaining (`inst - paidC - paidRho`) (cap, do not revert on overpay: pull only the capped amount). Allocation order: rho first, then c. `rho` part goes to `reserve` immediately; `rhoPaidTotal[i] += rho part`. The c part: if round t is settled, it is arrears: `claimable[recipient(t)] += cPart`; otherwise it counts in `paidC[t][i]` (pot). If the installment becomes complete (`paidC + paidRho == inst`) and this payment came from a wallet (always true here) and `t > slot(member)` (member already received) and `deposit[member] == d` and `depositCured[t][member] == false`: release `min(holdback[member], relPerInst)` from holdback to `claimable[member]`.
- `collect(uint8 t, address member)`: same effect, but pulls the remaining installment from `member` via allowance with a low-level `try/catch` on `transferFrom`; failure emits `CollectFailed(t, member)` and does NOT revert. Callable by anyone from `due(t)`.
- `topUpDeposit(uint256 amount)`: member Active, up to `d`.

### 5.5 Settling a round (`_settleRound(t)`, internal)

`roundReady(t)`: `now >= due(t) + grace`, OR every Active member other than `recipient(t)` has `paidC[t][i] + paidRho[t][i] == inst`. Settlement is strictly sequential.
- If `recipient(t)` is Defaulted (it quit before its turn): the round is skipped. For every member `i != recipient(t)`: `claimable[i] += paidC[t][i] + paidRho[t][i]` — but the rho part must be taken back out of `reserve` (so `reserve -= paidRho[t][i]` and `rhoPaidTotal[i] -= paidRho[t][i]`). Mark settled, emit `RoundSkipped(t)`.
- Else: `collected = sum over i != recipient(t) of paidC[t][i]` plus `c` for the recipient's own netted installment. `remaining = number of unsettled rounds r >= t whose recipient is not Defaulted` (including t). `covShare = coveragePool / remaining` (integer division); `pot = collected + covShare`; `coveragePool -= covShare`. `hb = min(hbAtReceipt(t), pot)`. The recipient's own `rho` for its round is netted: `ownRho = min(rho, pot - hb)`; `reserve += ownRho`; `rhoPaidTotal[recipient] += ownRho`. `payout = pot - hb - ownRho`. `holdback[recipient] += hb`; `claimable[recipient] += payout`. Mark settled, `nextRound++`, emit `RoundSettled(t, recipient, collected, covShare, hb, payout)`.

### 5.6 Resolving a missed installment, defaults

`resolveLate(uint8 t, address member)` anyone: state Active; `now >= due(t) + grace + cure`; member Active and `!= recipient(t)`; installment not complete. `missing = inst - paidC[t][member] - paidRho[t][member]`.
- If `deposit[member] >= missing`: cure. `deposit -= missing`; `depositUses++`; `depositCured[t][member] = true`; allocate exactly as `pay` does (rho first to reserve, then c to the pot or, if round settled, to `claimable[recipient(t)]`); emit `LateCured`. No holdback release for this installment.
- Else: `_default(member, t, msg.sender)`.

`_default(i, t, caller)`:
1. status = Defaulted. `arrearsDue = roundSettled[t] ? c - paidC[t][i] : 0`. `U = (c - paidC[t][i]) + c * (count of rounds r in t+1..n with r != slot(i))` (if round t unsettled, the unpaid part of round t is part of `U`; if `slot(i) == t` impossible here). If `slot(i) > t` (it never received), the same formula applies (its own slot is excluded, so its round will be skipped).
2. `collateral = holdback[i] + deposit[i]`; `bounty = min(DECLARE_BOUNTY, collateral)`; `claimable[caller] += bounty` (taken from deposit first, then holdback).
3. `seizable = collateral - bounty`; `seized = min(seizable, U)`; take from holdback first, then deposit; the excess `seizable - seized` goes to `claimable[i]` (never confiscate beyond the obligation). Zero `holdback[i]` and `deposit[i]`.
4. `reserveUse = min(U - seized, reserve * RESERVE_EVENT_CAP_BPS / BPS)`; `reserve -= reserveUse`.
5. `pool = seized + reserveUse`. If `arrearsDue > 0` and round t settled: pay `min(arrearsDue, pool)` to `claimable[recipient(t)]` first; `pool` reduced. Add the rest to `coveragePool`.
6. `unrecovered = U - seized - reserveUse`. Call `registry.record(i, address(this), unrecovered, issuerBlocked)` inside `try/catch` (a failure emits `RegistryWriteFailed(i)` and never reverts). `issuerBlocked` comes from `IUSDCBlacklist(USDC).isBlacklisted(i)` inside `try/catch` (false on failure).
7. Emit `Defaulted(i, t, U, seized, reserveUse, unrecovered, caller)`.

### 5.7 Closing and claiming

- `finalize()` anyone: state Active; `nextRound > n`; for every round and every Active member other than the recipient the installment must be complete, otherwise revert `PendingResolution`. Then: every Active member gets `claimable += deposit + holdback` (zero them); `reserve` (plus any `coveragePool` leftover) is split among Active members pro rata to `rhoPaidTotal` (dust stays in the contract, tracked); state Closed; emit `Closed`.
- `claim()`: `nonReentrant`; zero `claimable[msg.sender]` first, then `safeTransfer`. A failing token transfer reverts only this call.
- Views: `memberInfo(slot)`, `roundInfo(t)`, `state()`, `termsHash()`, `requiresAttestation(slot)`, `getTerms()`, `quoteDue(t)`.

### 5.8 Invariants the code must keep (document in NatSpec)

1. Sum of `claimable + holdback + deposit` over members, plus `reserve + coveragePool + dust + current-round unsettled collected C`, equals total USDC taken in minus USDC paid out via `claim`; nothing is created or lost.
2. A round settles once; a member receives its pot at most once.
3. No external call other than USDC `safeTransfer*`, `registry.isBanned` (in `accept`), `gate.verify` (in `accept`), `registry.record` and `USDC.isBlacklisted` (both try/catch, in `_default`).
4. Holdback of an Active member never exceeds `ceil(phiBps * c * remainingRounds / BPS)` and is only released by full installment payments.
5. Seized amount in a default never exceeds `U`.

## 6. GroupFactory

`constructor(address admin_, address implementation_, address gate_, uint16 minPhiBps_, uint16 minDepositBps_, uint256 minC_, uint256 maxC_, uint64 maxDuration_)`: reverts on zero `admin_`/`implementation_`; `gate_` may be zero; stores everything as immutable (admin in storage, two-step). Creates `registry = new DefaultRegistry(address(this))`. Public `registry`, `isGroup`, `groups(index)`, `groupCount`.

`createGroup(Terms calldata t) returns (address)`: not paused; validate: `4 <= n <= 10`, `members.length == n`, no zero or duplicate member; `c` in `[minC, maxC]`; `phiBps >= minPhiBps && <= BPS`; `rho <= c / 10`; `d >= c + rho` and `d >= c * minDepositBps / BPS`; `period >= 1 hours`, `grace >= 1 hours && <= 14 days`, `cure >= 1 hours && <= 7 days`; `n * period <= maxDuration`; `startTime > block.timestamp`; `acceptDeadline <= startTime`, `acceptDeadline > block.timestamp`; if `useGate`: `gate != 0`, `minScoreMilli >= MIN_SCORE_FLOOR_MILLI`; if `!useGate`: `minScoreMilli == 0`. Clone the implementation (`Clones.clone`), set `isGroup`, push to `groups`, call `initialize(t, registry, gate, msg.sender)`, emit `GroupCreated(group, creator, termsHash)`.

Admin: `pauseCreation()`, `unpauseCreation()`, `transferAdmin(address)`, `acceptAdmin()` (two-step). The admin can do NOTHING else.

## 7. Deployment parameters (testnet)

Admin `0x223c2D5Af8120cAb3c68b5587feC7c8649Ce9c15`; `minPhiBps 3000`; `minDepositBps 10000`; `minC 1_000_000`; `maxC 1_000_000_000`; `maxDuration 31_536_000`. The implementation is deployed first (no constructor args), then the gate (attester), then the factory.
