// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Terms, Attestation, IRosca, IDefaultRegistry, IPassportGate, IUSDCBlacklist} from "./IRosca.sol";

/**
 * @notice Fixed-USDC, immutable-logic ROSCA clone. No owner or administrative fund access.
 * @dev Accounted inflows minus claims equal all address claimables, deposits, holdbacks,
 * reserve, coveragePool, dust and principal escrow across ALL unsettled rounds. Direct
 * donations are not liabilities. Refundable rho is a subset of reserve, not another bucket.
 * Recipient principal netting is not a token inflow: gross collected includes its c,
 * but that same c is deducted before allocating funded holdback, reserve and payout.
 * Each round settles once and each member receives at most one pot. Collateral seized
 * never exceeds principal obligation U; only USDC, registry and gate calls are permitted.
 * Holdback starts at ceil(phi*c*(n-slot)/BPS), capped by funded pot, and is released only
 * by eligible full wallet installments or returned on close/default. Deposit cures do
 * not release it. Accordingly the spec's time-based decreasing holdback bound is not
 * asserted after cures: it conflicts with the explicit no-release cure rule.
 */
contract RoscaGroup is Initializable, ReentrancyGuard, IRosca {
    using SafeERC20 for IERC20;

    address public constant USDC = 0x3600000000000000000000000000000000000000;
    uint256 public constant BPS = 10_000;
    uint256 public constant DECLARE_BOUNTY = 50_000;
    uint256 public constant RESERVE_EVENT_CAP_BPS = 5_000;
    uint32 public constant MIN_SCORE_FLOOR_MILLI = 20_000;

    enum State { Recruiting, Locked, Active, Closed, Cancelled }
    enum Status { None, Accepted, Active, Defaulted }
    struct Member {
        Status status;
        uint256 deposit;
        uint256 holdback;
        uint256 rhoPaidTotal;
        uint8 depositUses;
    }
    struct MemberView {
        address wallet;
        Status status;
        uint256 deposit;
        uint256 holdback;
        uint256 claimable;
        uint256 rhoPaidTotal;
        uint8 depositUses;
    }
    struct RoundView {
        uint256 due;
        address recipient;
        bool settled;
        bool skipped;
        bool ready;
        uint256[] principalPaid;
        uint256[] reservePaid;
    }
    struct DefaultAmounts {
        uint256 obligation;
        uint256 arrears;
        uint256 collateral;
        uint256 bounty;
        uint256 seized;
        uint256 reserveUse;
        uint256 unrecovered;
    }

    Terms private _terms;
    Member[] private _members;
    bool[] public needsAtt;
    mapping(address => uint8) public slotOf;
    mapping(address => uint256) public claimable;
    mapping(bytes32 => bool) public usedNonce;
    // Round numbers are 1-based; the inner member index is slot - 1.
    mapping(uint8 => mapping(uint256 => uint256)) public paidC;
    mapping(uint8 => mapping(uint256 => uint256)) public paidRho;
    mapping(uint8 => mapping(uint256 => bool)) public depositCured;
    mapping(uint8 => bool) public roundSettled;
    mapping(uint8 => bool) public roundSkipped;
    State public state;
    bytes32 public override termsHash;
    address public registry;
    address public gate;
    address public creator;
    uint256 public inst;
    uint256 public relPerInst;
    uint256 public reserve;
    uint256 public coveragePool;
    uint256 public dust;
    uint8 public nextRound;
    uint8 public acceptedCount;
    // All unsettled-round rho must remain refundable if that recipient defaults.
    uint256 public refundableRho;
    /// @dev Unfunded receipt-target holdback per round, reduced only by late principal allocations.
    mapping(uint8 => uint256) private hbShortfall;

    error InvalidState();
    error InvalidTerms();
    error InvalidSlot();
    error InvalidRound();
    error InvalidMember();
    error DeadlinePassed();
    error TooEarly();
    error Banned();
    error InvalidAttestation();
    error NonceUsed();
    error InsufficientReceived();
    error NothingMissing();
    error PendingResolution();
    error EarlierInstallmentPending(uint8 round);

    event GroupInitialized(bytes32 indexed termsHash, address indexed creator, address registry, address gate);
    event Accepted(address indexed member, uint8 slot, uint256 deposit);
    event AttestationUsed(address indexed member, uint256 nonce);
    event Withdrawn(address indexed member, uint256 amount);
    event Locked();
    event Activated();
    event Cancelled();
    event DepositRefunded(address indexed member, uint256 amount);
    event Payment(uint8 indexed round, address indexed member, address indexed payer, uint256 rhoPart, uint256 cPart, bool fromDeposit);
    event CollectFailed(uint8 indexed round, address indexed member);
    event DepositToppedUp(address indexed member, uint256 amount);
    event HoldbackReleased(address indexed member, uint8 indexed round, uint256 amount);
    event RoundSettled(uint8 indexed round, address indexed recipient, uint256 collected, uint256 covShare, uint256 hb, uint256 payout);
    event RoundSkipped(uint8 indexed round);
    event LateCured(uint8 indexed round, address indexed member, uint256 amount);
    event Defaulted(address indexed member, uint8 indexed round, uint256 obligation, uint256 seized, uint256 reserveUse, uint256 unrecovered, address caller);
    event RegistryWriteFailed(address indexed member);
    event CollateralReturned(address indexed member, uint256 amount);
    event ReserveDistributed(address indexed member, uint256 amount);
    event Closed(uint256 dust);
    event Claimed(address indexed wallet, uint256 amount);

    /// @notice Lock the implementation itself; clones initialize their independent storage.
    constructor() { _disableInitializers(); }

    /// @inheritdoc IRosca
    function initialize(Terms calldata t, address registry_, address gate_, address creator_)
        external override initializer nonReentrant
    {
        _sync();
        if (registry_ == address(0) || creator_ == address(0) || t.n < 4 || t.n > 10
            || t.members.length != t.n || t.c == 0 || t.phiBps > BPS
            || t.rho > t.c / 10 || t.d < t.c + t.rho) revert InvalidTerms();
        _terms = t;
        registry = registry_;
        gate = gate_;
        creator = creator_;
        inst = t.c + t.rho;
        relPerInst = Math.mulDiv(t.c, t.phiBps, BPS, Math.Rounding.Ceil);
        nextRound = 1;
        termsHash = keccak256(abi.encode(block.chainid, address(this), t));
        for (uint256 i; i < t.n; ++i) {
            address wallet = t.members[i];
            if (wallet == address(0) || slotOf[wallet] != 0) revert InvalidMember();
            slotOf[wallet] = uint8(i + 1);
            _members.push(Member(Status.None, 0, 0, 0, 0));
            needsAtt.push(false);
        }
        if (t.useGate) _markGatedSlots();
        emit GroupInitialized(termsHash, creator_, registry_, gate_);
    }

    /// @notice Persist lazy activation, cancellation and sequential settlements without another action.
    function sync() external nonReentrant { _sync(); }

    /// @notice Accept the immutable proposal and escrow the member's full deposit.
    function accept(Attestation calldata att) external nonReentrant {
        _sync();
        if (state != State.Recruiting) revert InvalidState();
        if (block.timestamp > _terms.acceptDeadline) revert DeadlinePassed();
        uint256 i = _index(msg.sender);
        Member storage m = _members[i];
        if (m.status != Status.None) revert InvalidMember();
        if (IDefaultRegistry(registry).isBanned(msg.sender)) revert Banned();
        if (_terms.useGate && needsAtt[i]) {
            bytes32 key = keccak256(abi.encode(msg.sender, att.nonce));
            if (usedNonce[key]) revert NonceUsed();
            if (gate == address(0) || att.scoreMilli <= _terms.minScoreMilli
                || !IPassportGate(gate).verify(msg.sender, termsHash, att.scoreMilli, att.expiresAt, att.nonce, att.sig)) {
                revert InvalidAttestation();
            }
            usedNonce[key] = true;
            emit AttestationUsed(msg.sender, att.nonce);
        }
        _pull(msg.sender, _terms.d);
        m.deposit = _terms.d;
        m.status = Status.Accepted;
        ++acceptedCount;
        emit Accepted(msg.sender, uint8(i + 1), _terms.d);
        if (acceptedCount == _terms.n) {
            state = State.Locked;
            emit Locked();
        }
    }

    /// @notice Withdraw while recruiting, or cancel the entire locked pre-start group.
    function withdraw() external nonReentrant {
        _sync();
        uint256 i = _index(msg.sender);
        Member storage m = _members[i];
        if (m.status != Status.Accepted) revert InvalidMember();
        if (state == State.Locked) { _cancel(); return; }
        if (state != State.Recruiting) revert InvalidState();
        uint256 amount = m.deposit;
        m.deposit = 0;
        m.status = Status.None;
        --acceptedCount;
        claimable[msg.sender] += amount;
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Cancel expired recruitment or a locked group untouched for one full period.
    /// @dev Timeout cancellation takes precedence over lazy activation in this entry point.
    function cancel() external nonReentrant {
        bool lockedTimeout = state == State.Locked
            && block.timestamp >= uint256(_terms.startTime) + _terms.period;
        // Preserve the timeout branch before _sync would activate the untouched group.
        if (lockedTimeout) {
            _cancel();
            _sync();
            return;
        }
        _sync();
        if (state == State.Cancelled) return;
        if (state != State.Recruiting || block.timestamp <= _terms.acceptDeadline) revert InvalidState();
        _cancel();
    }

    /// @notice Pay another member's due installment, pulling only its outstanding amount.
    function pay(uint8 t, address member, uint256 amount) external nonReentrant {
        _sync();
        uint256 i = _paymentIndex(t, member);
        uint256 capped = Math.min(amount, _remaining(t, i));
        if (capped == 0) return;
        _pull(msg.sender, capped);
        _allocate(t, i, capped, false, msg.sender);
        _settleReady();
    }

    /// @notice Attempt allowance collection; token-call failures emit CollectFailed without reverting.
    function collect(uint8 t, address member) external nonReentrant {
        _sync();
        uint256 i = _paymentIndex(t, member);
        uint256 amount = _remaining(t, i);
        if (amount == 0) return;
        uint256 beforeBalance = IERC20(USDC).balanceOf(address(this));
        bool success;
        try IERC20(USDC).transferFrom(member, address(this), amount) returns (bool ok) {
            success = ok;
        } catch { }
        if (!success) { emit CollectFailed(t, member); return; }
        _checkReceived(beforeBalance, amount);
        _allocate(t, i, amount, false, member);
        _settleReady();
    }

    /// @notice Restore the caller's deposit up to d; does not retroactively release holdback.
    function topUpDeposit(uint256 amount) external nonReentrant {
        _sync();
        if (state != State.Active) revert InvalidState();
        uint256 i = _index(msg.sender);
        if (_members[i].status != Status.Active) revert InvalidMember();
        uint256 capped = Math.min(amount, _terms.d - _members[i].deposit);
        if (capped == 0) return;
        _pull(msg.sender, capped);
        _members[i].deposit += capped;
        emit DepositToppedUp(msg.sender, capped);
    }

    /// @notice Cure the earliest unresolved installment from deposit, or declare a default.
    /// @dev Chronological resolution prevents selecting a later round to omit earlier arrears.
    function resolveLate(uint8 t, address member) external nonReentrant {
        _sync();
        uint256 i = _paymentIndex(t, member);
        if (block.timestamp < _due(t) + _terms.grace + _terms.cure) revert TooEarly();
        uint256 missing = _remaining(t, i);
        if (missing == 0) revert NothingMissing();
        for (uint8 r = 1; r < t; ++r) {
            if (r != i + 1 && !roundSkipped[r] && _remaining(r, i) != 0) {
                revert EarlierInstallmentPending(r);
            }
        }
        Member storage m = _members[i];
        if (m.deposit >= missing) {
            m.deposit -= missing;
            ++m.depositUses;
            depositCured[t][i] = true;
            _allocate(t, i, missing, true, member);
            emit LateCured(t, member, missing);
        } else _default(i, t, msg.sender);
        _settleReady();
    }

    /// @notice Close only after all non-skipped active obligations have been paid or resolved.
    function finalize() external nonReentrant {
        _sync();
        if (state != State.Active || nextRound <= _terms.n) revert InvalidState();
        uint256 weights;
        uint256 activeCount;
        for (uint256 i; i < _terms.n; ++i) {
            Member storage m = _members[i];
            if (m.status != Status.Active) continue;
            ++activeCount;
            for (uint8 r = 1; r <= _terms.n; ++r) {
                if (r != i + 1 && !roundSkipped[r] && _remaining(r, i) != 0) revert PendingResolution();
            }
            uint256 collateral = m.deposit + m.holdback;
            claimable[_terms.members[i]] += collateral;
            m.deposit = 0;
            m.holdback = 0;
            weights += m.rhoPaidTotal;
            emit CollateralReturned(_terms.members[i], collateral);
        }
        uint256 distributable = reserve + coveragePool;
        reserve = 0;
        coveragePool = 0;
        uint256 distributed;
        // Zero-weight fallback: when no rho was paid, split equally among Active members so a leftover
        // coverage pool is never stranded; only integer-division remainders become dust.
        if (activeCount != 0) {
            for (uint256 i; i < _terms.n; ++i) {
                if (_members[i].status != Status.Active) continue;
                uint256 share = weights != 0
                    ? Math.mulDiv(distributable, _members[i].rhoPaidTotal, weights)
                    : distributable / activeCount;
                claimable[_terms.members[i]] += share;
                distributed += share;
                emit ReserveDistributed(_terms.members[i], share);
            }
        }
        dust += distributable - distributed;
        state = State.Closed;
        emit Closed(dust);
    }

    /// @notice Withdraw only the caller's accrued entitlement; failure affects this call alone.
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) return;
        claimable[msg.sender] = 0;
        IERC20(USDC).safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice Return the full immutable proposal, including slot-ordered membership.
    function getTerms() external view returns (Terms memory) { return _terms; }

    /// @notice Return the caller-independent accounting for a 1-based member slot.
    function memberInfo(uint8 slot) external view returns (MemberView memory info) {
        if (slot == 0 || slot > _terms.n) revert InvalidSlot();
        Member storage m = _members[slot - 1];
        address wallet = _terms.members[slot - 1];
        info = MemberView(wallet, m.status, m.deposit, m.holdback, claimable[wallet], m.rhoPaidTotal, m.depositUses);
    }

    /// @notice Return settlement state and payment arrays (inner indices are slot - 1).
    function roundInfo(uint8 t) external view returns (RoundView memory info) {
        _checkRound(t);
        info.due = _due(t);
        info.recipient = _terms.members[t - 1];
        info.settled = roundSettled[t];
        info.skipped = roundSkipped[t];
        info.ready = !roundSettled[t] && _roundReady(t);
        info.principalPaid = new uint256[](_terms.n);
        info.reservePaid = new uint256[](_terms.n);
        for (uint256 i; i < _terms.n; ++i) {
            info.principalPaid[i] = paidC[t][i];
            info.reservePaid[i] = paidRho[t][i];
        }
    }

    /// @notice Return the unfunded receipt-target holdback for a valid 1-based round.
    /// @dev Zero before settlement; not reduced by releases or default arrears routing.
    ///      A Defaulted recipient's shortfall is not funded by subsequent payments.
    function hbShortfallOf(uint8 t) external view returns (uint256) {
        _checkRound(t);
        return hbShortfall[t];
    }

    /// @notice Whether the specified 1-based slot must provide a Passport attestation.
    function requiresAttestation(uint8 slot) external view returns (bool) {
        if (slot == 0 || slot > _terms.n) revert InvalidSlot();
        return needsAtt[slot - 1];
    }

    /// @notice Return a round's due timestamp; no future installment can be collected early.
    function quoteDue(uint8 t) external view returns (uint256) { _checkRound(t); return _due(t); }

    /// @notice Whether a due, unsettled round satisfies grace or payment readiness.
    function roundReady(uint8 t) external view returns (bool) {
        _checkRound(t);
        return !roundSettled[t] && _roundReady(t);
    }

    /// @notice Target holdback at receipt before the funded-pot cap.
    function hbAtReceipt(uint8 t) public view returns (uint256) {
        _checkRound(t);
        return Math.mulDiv(_terms.c, uint256(_terms.phiBps) * (_terms.n - t), BPS, Math.Rounding.Ceil);
    }

    function _sync() private {
        // initialize calls this before setting terms; an uninitialized clone has n == 0.
        if (_terms.n == 0) return;
        if (state == State.Locked && block.timestamp >= _terms.startTime) {
            state = State.Active;
            for (uint256 i; i < _terms.n; ++i) _members[i].status = Status.Active;
            emit Activated();
        } else if (state == State.Recruiting && block.timestamp >= _terms.startTime) _cancel();
        _settleReady();
    }

    function _settleReady() private {
        if (state != State.Active) return;
        while (nextRound <= _terms.n && _roundReady(nextRound)) _settleRound(nextRound);
    }

    function _cancel() private {
        state = State.Cancelled;
        for (uint256 i; i < _terms.n; ++i) {
            Member storage m = _members[i];
            if (m.status != Status.Accepted) continue;
            uint256 amount = m.deposit;
            m.deposit = 0;
            m.status = Status.None;
            claimable[_terms.members[i]] += amount;
            emit DepositRefunded(_terms.members[i], amount);
        }
        acceptedCount = 0;
        emit Cancelled();
    }

    function _roundReady(uint8 t) private view returns (bool) {
        if (state != State.Active || block.timestamp < _due(t)) return false;
        if (block.timestamp >= _due(t) + _terms.grace) return true;
        for (uint256 i; i < _terms.n; ++i) {
            if (i != t - 1 && _members[i].status == Status.Active && _remaining(t, i) != 0) return false;
        }
        return true;
    }

    function _settleRound(uint8 t) private {
        uint256 recipientIndex = t - 1;
        roundSettled[t] = true;
        ++nextRound;
        if (_members[recipientIndex].status == Status.Defaulted) {
            roundSkipped[t] = true;
            for (uint256 i; i < _terms.n; ++i) {
                if (i == recipientIndex) continue;
                uint256 rhoPart = paidRho[t][i];
                reserve -= rhoPart;
                refundableRho -= rhoPart;
                _members[i].rhoPaidTotal -= rhoPart;
                claimable[_terms.members[i]] += paidC[t][i] + rhoPart;
            }
            emit RoundSkipped(t);
            return;
        }
        uint256 collected = _terms.c;
        for (uint256 i; i < _terms.n; ++i) {
            if (i == recipientIndex) continue;
            collected += paidC[t][i];
            refundableRho -= paidRho[t][i];
        }
        uint256 remaining;
        for (uint8 r = t; r <= _terms.n; ++r) {
            if (_members[r - 1].status != Status.Defaulted) ++remaining;
        }
        uint256 covShare = coveragePool / remaining;
        coveragePool -= covShare;
        // Subtract the recipient's own netted principal: it was never transferred in.
        uint256 fundedPot = collected - _terms.c + covShare;
        uint256 hb = Math.min(hbAtReceipt(t), fundedPot);
        hbShortfall[t] = hbAtReceipt(t) - hb;
        uint256 ownRho = Math.min(_terms.rho, fundedPot - hb);
        reserve += ownRho;
        Member storage recipient = _members[recipientIndex];
        recipient.rhoPaidTotal += ownRho;
        recipient.holdback += hb;
        uint256 payout = fundedPot - hb - ownRho;
        claimable[_terms.members[recipientIndex]] += payout;
        emit RoundSettled(t, _terms.members[recipientIndex], collected, covShare, hb, payout);
    }

    function _allocate(uint8 t, uint256 i, uint256 amount, bool fromDeposit, address payer) private {
        uint256 rhoPart = Math.min(amount, _terms.rho - paidRho[t][i]);
        uint256 cPart = amount - rhoPart;
        paidRho[t][i] += rhoPart;
        paidC[t][i] += cPart;
        reserve += rhoPart;
        _members[i].rhoPaidTotal += rhoPart;
        if (roundSettled[t]) {
            Member storage recipient = _members[t - 1];
            uint256 hbPart;
            if (recipient.status != Status.Defaulted && hbShortfall[t] != 0) {
                hbPart = Math.min(cPart, hbShortfall[t]);
                hbShortfall[t] -= hbPart;
                recipient.holdback += hbPart;
            }
            claimable[_terms.members[t - 1]] += cPart - hbPart;
        } else refundableRho += rhoPart;
        emit Payment(t, _terms.members[i], payer, rhoPart, cPart, fromDeposit);
        if (!fromDeposit && _remaining(t, i) == 0 && t > i + 1
            && _members[i].deposit == _terms.d && !depositCured[t][i]) {
            uint256 released = Math.min(_members[i].holdback, relPerInst);
            _members[i].holdback -= released;
            claimable[_terms.members[i]] += released;
            if (released != 0) emit HoldbackReleased(_terms.members[i], t, released);
        }
    }

    function _default(uint256 i, uint8 t, address caller) private {
        Member storage m = _members[i];
        m.status = Status.Defaulted;
        DefaultAmounts memory a;
        a.arrears = roundSettled[t] ? _terms.c - paidC[t][i] : 0;
        a.obligation = _terms.c - paidC[t][i];
        // Overlapping schedules can have later principal already paid; never seize it twice.
        for (uint8 r = t + 1; r <= _terms.n; ++r) {
            if (r != i + 1 && !roundSkipped[r]
                && (roundSettled[r] || _members[r - 1].status != Status.Defaulted)) {
                a.obligation += _terms.c - paidC[r][i];
            }
        }
        a.collateral = m.holdback + m.deposit;
        a.bounty = Math.min(DECLARE_BOUNTY, a.collateral);
        claimable[caller] += a.bounty;
        // Bounty is notionally deposit-first; seized remainder is holdback-first.
        // Both buckets are zeroed and their unseized excess returned, so the aggregate is identical.
        a.seized = Math.min(a.collateral - a.bounty, a.obligation);
        uint256 excess = a.collateral - a.bounty - a.seized;
        claimable[_terms.members[i]] += excess;
        m.holdback = 0;
        m.deposit = 0;
        // Refundable rho is in reserve but cannot fund a default before its round is settled.
        a.reserveUse = Math.min(a.obligation - a.seized,
            Math.min(Math.mulDiv(reserve, RESERVE_EVENT_CAP_BPS, BPS), reserve - refundableRho));
        reserve -= a.reserveUse;
        uint256 pool = a.seized + a.reserveUse;
        // Late synchronization may have settled several rounds. Route their arrears
        // chronologically before distributing any residual to future recipients.
        for (uint8 r = t; r <= _terms.n && pool != 0; ++r) {
            if (r == i + 1 || !roundSettled[r] || roundSkipped[r]) continue;
            uint256 arrearsPayment = Math.min(_terms.c - paidC[r][i], pool);
            claimable[_terms.members[r - 1]] += arrearsPayment;
            pool -= arrearsPayment;
        }
        coveragePool += pool;
        a.unrecovered = a.obligation - a.seized - a.reserveUse;
        _recordDefault(_terms.members[i], a.unrecovered);
        if (excess != 0) emit CollateralReturned(_terms.members[i], excess);
        emit Defaulted(_terms.members[i], t, a.obligation, a.seized, a.reserveUse, a.unrecovered, caller);
    }

    function _recordDefault(address wallet, uint256 unrecovered) private {
        bool issuerBlocked;
        try IUSDCBlacklist(USDC).isBlacklisted{gas: 50_000}(wallet) returns (bool blocked) {
            issuerBlocked = blocked;
        } catch { }
        try IDefaultRegistry(registry).record{gas: 150_000}(wallet, address(this), unrecovered, issuerBlocked) { }
        catch { emit RegistryWriteFailed(wallet); }
    }

    function _paymentIndex(uint8 t, address member) private view returns (uint256 i) {
        if (state != State.Active) revert InvalidState();
        _checkRound(t);
        i = _index(member);
        if (_members[i].status != Status.Active || i == t - 1) revert InvalidMember();
        if (block.timestamp < _due(t)) revert TooEarly();
        // No further obligation exists for a forfeited recipient's skipped round.
        if (roundSkipped[t] || (!roundSettled[t] && _members[t - 1].status == Status.Defaulted)) {
            revert InvalidRound();
        }
    }

    function _remaining(uint8 t, uint256 i) private view returns (uint256) {
        return inst - paidC[t][i] - paidRho[t][i];
    }

    function _index(address wallet) private view returns (uint256) {
        uint8 slot = slotOf[wallet];
        if (slot == 0) revert InvalidMember();
        return slot - 1;
    }

    function _checkRound(uint8 t) private view {
        if (t == 0 || t > _terms.n) revert InvalidRound();
    }

    function _due(uint8 t) private view returns (uint256) {
        return uint256(_terms.startTime) + uint256(t - 1) * _terms.period;
    }

    function _pull(address from, uint256 amount) private {
        uint256 beforeBalance = IERC20(USDC).balanceOf(address(this));
        IERC20(USDC).safeTransferFrom(from, address(this), amount);
        _checkReceived(beforeBalance, amount);
    }

    function _checkReceived(uint256 beforeBalance, uint256 amount) private {
        uint256 afterBalance = IERC20(USDC).balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance < amount) revert InsufficientReceived();
        // Positive transfer surplus is tracked, not used to size any member obligation.
        dust += afterBalance - beforeBalance - amount;
    }

    function _markGatedSlots() private {
        uint256[] memory exposure = new uint256[](_terms.n);
        uint256 sum;
        for (uint256 i; i < _terms.n; ++i) {
            uint256 gross = Math.mulDiv(_terms.c, (BPS - _terms.phiBps) * (_terms.n - i - 1), BPS);
            exposure[i] = gross > _terms.d ? gross - _terms.d : 0;
            if (exposure[i] > _terms.ungatedCap) needsAtt[i] = true;
            else sum += exposure[i];
        }
        while (sum > _terms.ungatedCap) {
            uint256 largest;
            uint256 chosen;
            for (uint256 i; i < _terms.n; ++i) {
                if (!needsAtt[i] && exposure[i] > largest) { largest = exposure[i]; chosen = i; }
            }
            needsAtt[chosen] = true;
            sum -= largest;
        }
    }
}
