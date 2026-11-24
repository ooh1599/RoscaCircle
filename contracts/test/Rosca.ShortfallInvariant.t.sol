// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RoscaBase} from "./Rosca.Base.t.sol";
import {RoscaHandler} from "./Rosca.Invariant.t.sol";
import {RoscaGroup} from "../RoscaGroup.sol";
import {Terms} from "../IRosca.sol";

/// @dev Same handler as the main invariant suite, but against the shortfall-prone regression terms:
/// n=10, c=100e6, phiBps=5000, d=100e6, rho=0 (hbAtReceipt(1)=450e6 and funded pots are often small).
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 200
contract RoscaShortfallInvariantTest is RoscaBase {
    RoscaGroup internal g;
    RoscaHandler internal handler;
    uint8 internal constant N = 10;

    function setUp() public override {
        super.setUp();
        Terms memory t = terms(N, 100e6, 5000, 100e6, 0);
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

    function _unsettledPrincipal() internal view returns (uint256 sum) {
        for (uint8 t = 1; t <= N; ++t) {
            if (g.roundSettled(t)) continue;
            for (uint256 i; i < N; ++i) if (i != t - 1) sum += g.paidC(t, i);
        }
    }

    /// Nothing created or lost: holdings = liabilities + unsettled round principal + dust,
    /// including late principal split between holdback refills and claimable.
    function invariant_ExactConservation() public view {
        assertEq(usdc.balanceOf(address(g)), _owed() + _unsettledPrincipal() + g.dust());
    }

    function invariant_HoldbackPlusShortfallWithinTarget() public view {
        for (uint8 s = 1; s <= N; ++s) {
            uint256 sf = g.hbShortfallOf(s);
            if (!g.roundSettled(s)) assertEq(sf, 0);
            assertLe(g.memberInfo(s).holdback + sf, g.hbAtReceipt(s));
        }
    }

    function invariant_SettlementIsSequential() public view {
        uint8 next = g.nextRound();
        for (uint8 t = 1; t <= N; ++t) assertEq(g.roundSettled(t), t < next);
    }
}
