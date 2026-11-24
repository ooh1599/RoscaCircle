// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {RoscaBase} from "./Rosca.Base.t.sol";
import {RoscaGroup} from "../RoscaGroup.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {Terms} from "../IRosca.sol";

/// @dev Drives bounded random actions against an active n=5 group. Every call is wrapped so reverts
/// (invalid state, too early, ...) are simply ignored; only successful state changes are explored.
contract RoscaHandler is Test {
    RoscaGroup public g;
    address[] public actors; // members + keeper
    uint256 public calls;
    uint8 internal n;

    constructor(RoscaGroup g_, address[] memory members, address keeper) {
        g = g_;
        n = uint8(members.length);
        for (uint256 i; i < members.length; ++i) actors.push(members[i]);
        actors.push(keeper);
    }

    function _a(uint256 i) internal view returns (address) { return actors[bound(i, 0, actors.length - 1)]; }
    function _mem(uint256 i) internal view returns (address) { return actors[bound(i, 0, actors.length - 2)]; }
    function _round(uint256 t) internal view returns (uint8) {
        // choose among rounds that are already due so most calls are meaningful
        Terms memory tm = g.getTerms();
        uint256 k = block.timestamp < tm.startTime ? 1 : (block.timestamp - tm.startTime) / tm.period + 1;
        if (k > n) k = n;
        return uint8(bound(t, 1, k));
    }

    function warp(uint256 s) external {
        vm.warp(block.timestamp + bound(s, 0, 5 hours));
        calls++;
    }

    function pay(uint256 t, uint256 mi, uint256 amt, uint256 payer) external {
        address who = _mem(payer);
        address member = _mem(mi);
        uint8 r = _round(t);
        amt = bound(amt, 0, 130e6);
        vm.prank(who);
        try g.pay(r, member, amt) {} catch {}
        calls++;
    }

    function payFull(uint256 t, uint256 mi) external {
        address member = _mem(mi);
        uint8 r = _round(t);
        vm.prank(member);
        try g.pay(r, member, 1_000e6) {} catch {}
        calls++;
    }

    /// @dev Members flagged in `mask` pay their full installment for round t; the rest stay silent.
    function payMasked(uint256 t, uint256 mask) external {
        uint8 r = _round(t);
        for (uint256 i; i < n; ++i) {
            if ((mask >> i) & 1 == 0) continue;
            address member = actors[i];
            vm.prank(member);
            try g.pay(r, member, 1_000e6) {} catch {}
        }
        calls++;
    }

    /// @dev Keeper sweep: try to resolve every (round, member) pair once the cure window has passed.
    function resolveAll(uint256 caller) external {
        address who = _a(caller);
        for (uint8 r = 1; r <= n; ++r) {
            for (uint256 i; i < n; ++i) {
                vm.prank(who);
                try g.resolveLate(r, actors[i]) {} catch {}
            }
        }
        calls++;
    }

    function collect(uint256 t, uint256 mi) external {
        try g.collect(_round(t), _mem(mi)) {} catch {}
        calls++;
    }

    function resolveLate(uint256 t, uint256 mi, uint256 caller) external {
        address who = _a(caller);
        uint8 r = _round(t);
        address member = _mem(mi);
        vm.prank(who);
        try g.resolveLate(r, member) {} catch {}
        calls++;
    }

    function topUp(uint256 mi, uint256 amt) external {
        address who = _mem(mi);
        amt = bound(amt, 0, 130e6);
        vm.prank(who);
        try g.topUpDeposit(amt) {} catch {}
        calls++;
    }

    function claim(uint256 who) external {
        address a = _a(who);
        vm.prank(a);
        try g.claim() {} catch {}
        calls++;
    }

    function sync() external {
        try g.sync() {} catch {}
        calls++;
    }

    function finalize() external {
        try g.finalize() {} catch {}
        calls++;
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 200
contract RoscaInvariantTest is RoscaBase {
    RoscaGroup internal g;
    RoscaHandler internal handler;
    uint8 internal constant N = 5;

    function setUp() public override {
        super.setUp();
        Terms memory t = terms(N, 100e6, 5000, 120e6, 10e6);
        t.period = 4 hours;
        t.grace = 1 hours;
        t.cure = 1 hours;
        g = newGroup(t);
        acceptAll(g);
        startGroup(g);
        address[] memory members = new address[](N);
        for (uint256 i; i < N; ++i) members[i] = m[i];
        handler = new RoscaHandler(g, members, keeper);
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](11);
        sels[0] = RoscaHandler.warp.selector;
        sels[1] = RoscaHandler.pay.selector;
        sels[2] = RoscaHandler.payFull.selector;
        sels[3] = RoscaHandler.collect.selector;
        sels[4] = RoscaHandler.resolveLate.selector;
        sels[5] = RoscaHandler.topUp.selector;
        sels[6] = RoscaHandler.claim.selector;
        sels[7] = RoscaHandler.sync.selector;
        sels[8] = RoscaHandler.finalize.selector;
        sels[9] = RoscaHandler.payMasked.selector;
        sels[10] = RoscaHandler.resolveAll.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function _owed() internal view returns (uint256 owed) {
        owed = g.reserve() + g.coveragePool();
        for (uint8 s = 1; s <= N; ++s) {
            RoscaGroup.MemberView memory mv = g.memberInfo(s);
            owed += mv.deposit + mv.holdback + mv.claimable;
        }
        owed += g.claimable(keeper);
    }

    /// Principal paid into rounds that have not settled yet is held but not yet attributed to anyone.
    function _unsettledPrincipal() internal view returns (uint256 sum) {
        for (uint8 t = 1; t <= N; ++t) {
            if (g.roundSettled(t)) continue;
            for (uint256 i; i < N; ++i) if (i != t - 1) sum += g.paidC(t, i);
        }
    }

    /// Headline property: total USDC held by the group always covers claimable + holdback + deposit + reserve + coveragePool.
    function invariant_GroupBalanceCoversAllLiabilities() public view {
        assertGe(usdc.balanceOf(address(g)), _owed());
    }

    /// Exact conservation: holdings = liabilities + unsettled round principal + tracked dust. Nothing created or lost.
    function invariant_ExactConservation() public view {
        assertEq(usdc.balanceOf(address(g)), _owed() + _unsettledPrincipal() + g.dust());
    }

    /// Refundable rho is a subset of reserve, never an extra bucket.
    function invariant_RefundableRhoWithinReserve() public view {
        assertLe(g.refundableRho(), g.reserve());
    }

    /// Rounds settle strictly in order and at most once.
    function invariant_SettlementIsSequential() public view {
        uint8 next = g.nextRound();
        for (uint8 t = 1; t <= N; ++t) assertEq(g.roundSettled(t), t < next);
    }

    /// A member's holdback never exceeds what its receipt could have held back (no phantom holdback).
    function invariant_HoldbackBounded() public view {
        for (uint8 s = 1; s <= N; ++s) assertLe(g.memberInfo(s).holdback, g.hbAtReceipt(s));
    }

    /// hbShortfall bookkeeping: zero until the round settles, and holdback + shortfall never exceeds the target
    /// (holdback only grows via shortfall refills; releases/seizures only shrink it).
    function invariant_ShortfallConsistentWithHoldback() public view {
        for (uint8 s = 1; s <= N; ++s) {
            uint256 sf = g.hbShortfallOf(s);
            if (!g.roundSettled(s)) assertEq(sf, 0);
            assertLe(sf, g.hbAtReceipt(s));
            assertLe(g.memberInfo(s).holdback + sf, g.hbAtReceipt(s));
        }
    }

    /// Deposits never exceed d.
    function invariant_DepositNeverAboveD() public view {
        for (uint8 s = 1; s <= N; ++s) assertLe(g.memberInfo(s).deposit, 120e6);
    }
}
