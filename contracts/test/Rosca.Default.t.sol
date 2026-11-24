// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {RoscaBase} from "./Rosca.Base.t.sol";
import {RoscaGroup} from "../RoscaGroup.sol";
import {Terms} from "../IRosca.sol";

contract RevertingRegistry {
    function isBanned(address) external pure returns (bool) { return false; }
    function record(address, address, uint256, bool) external pure { revert("registry down"); }
}

contract RoscaDefaultTest is RoscaBase {
    uint256 internal constant BOUNTY = 50_000;

    event Defaulted(address indexed member, uint8 indexed round, uint256 obligation, uint256 seized, uint256 reserveUse, uint256 unrecovered, address caller);
    event RoundSettled(uint8 indexed round, address indexed recipient, uint256 collected, uint256 covShare, uint256 hb, uint256 payout);
    event RoundSkipped(uint8 indexed round);
    event RegistryWriteFailed(address indexed member);
    event CollateralReturned(address indexed member, uint256 amount);

    function _fresh() internal view returns (Terms memory t) {
        t = baseTerms();
        t.startTime = uint64(block.timestamp + 3 days);
        t.acceptDeadline = uint64(block.timestamp + 3 days - 1 hours);
    }

    function _hasLog(Vm.Log[] memory logs, bytes32 sig, address emitter, uint256 topic1) internal pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == sig && logs[i].topics.length > 1
                && uint256(logs[i].topics[1]) == topic1) return true;
        }
        return false;
    }

    function _loss(uint256 from, uint256 to) internal view returns (int256 l) {
        for (uint256 i = from; i <= to; ++i) l -= netOf(i);
    }

    function _sumAll(RoscaGroup g, uint256 n) internal view returns (int256 s) {
        for (uint256 i; i < n; ++i) s += netOf(i);
        s += int256(usdc.balanceOf(keeper)) + int256(usdc.balanceOf(address(g)));
    }

    // ---------- oracle S1 ----------
    function _runS1() internal returns (RoscaGroup g) {
        g = activeGroup(baseTerms());
        uint8[] memory p = allPay(10);
        p[0] = 1; // slot 1 receives round 1 then stops paying
        runStops(g, p);
    }

    function test_S1_TotalLossMatchesOracle() public {
        RoscaGroup g = _runS1();
        // oracle (rosca_scenarios.py S1): total victim loss 350e6; the only extra is the 0.05 USDC declare bounty
        assertApproxEqAbs(uint256(_loss(1, 9)) - BOUNTY, 350e6, 10);
        assertEq(usdc.balanceOf(keeper), BOUNTY);
        // oracle average per victim 38.888888e6
        assertApproxEqAbs((uint256(_loss(1, 9)) - BOUNTY) / 9, 38_888_888, 2);
        assertEq(_sumAll(g, 10), 0, "nothing created or lost");
        assertEq(g.dust(), 0);
    }

    /// @dev DIVERGENCE FROM ORACLE (documented, see report): the sim equalises the loss over slots 2-10 because it
    /// declares the default before round 2 settles. On-chain a miss can only be resolved after grace+cure, by which
    /// time rounds 2 and 3 are settled, so spec 5.6 step 5 pays those recipients' arrears first (slot 2 via deposit
    /// cure, slot 3 via seized collateral) and the residual coverage is split over rounds 4-10 only.
    function test_S1_PerVictimDistributionArrearsFirst() public {
        _runS1();
        assertEq(netOf(1), 0, "slot 2 made whole by deposit cure");
        assertEq(netOf(2), 0, "slot 3 made whole by arrears priority");
        for (uint256 i = 3; i < 10; ++i) assertApproxEqAbs(netOf(i), -50_007_143, 1);
        assertEq(netOf(0), 350e6, "defaulter kept the pot it never repaid net of collateral");
    }

    function test_S1_DefaulterBannedAndCannotJoinNewGroup() public {
        _runS1();
        assertEq(registry.defaultCount(m[0]), 1);
        assertApproxEqAbs(registry.openUnrecovered(m[0]), 350_050_000, 0);
        assertTrue(registry.isBanned(m[0]));
        RoscaGroup g2 = newGroup(_fresh());
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.Banned.selector);
        g2.accept(noAtt());
        // others are not banned
        vm.prank(m[1]);
        g2.accept(noAtt());
    }

    function test_S1_IssuerBlockedWalletNotBanned() public {
        usdc.setBlacklisted(m[0], true);
        _runS1();
        assertEq(registry.defaultCount(m[0]), 1);
        assertEq(registry.blockedCount(m[0]), 1);
        assertEq(registry.openUnrecovered(m[0]), 0);
        assertFalse(registry.isBanned(m[0]));
    }

    // ---------- the waterfall step by step (S1 manual) ----------
    function _s1UntilDefaultReady() internal returns (RoscaGroup g) {
        g = activeGroup(baseTerms());
        vm.warp(g.quoteDue(1));
        payRound(g, 1);
        // round 2: slot 1 does not pay
        vm.warp(g.quoteDue(2));
        for (uint256 i = 2; i < 10; ++i) {
            vm.prank(m[i]);
            g.pay(2, m[i], 100e6);
        }
        vm.warp(g.quoteDue(2) + GRACE + CURE);
        vm.prank(keeper);
        g.resolveLate(2, m[0]); // deposit (100) covers installment: cure, depositUses 1
        assertEq(g.memberInfo(1).deposit, 0);
        // round 3: slot 1 does not pay
        vm.warp(g.quoteDue(3));
        for (uint256 i = 1; i < 10; ++i) {
            if (i == 2) continue;
            vm.prank(m[i]);
            g.pay(3, m[i], 100e6);
        }
        vm.warp(g.quoteDue(3) + GRACE + CURE);
    }

    function test_Waterfall_DefaultEventAmountsAndCoveragePool() public {
        RoscaGroup g = _s1UntilDefaultReady();
        // holdback 450, deposit 0 -> collateral 450; bounty .05 from it; U = 100 (round 3) + 7*100 (rounds 4..10)
        vm.expectEmit(true, true, false, true, address(g));
        emit Defaulted(m[0], 3, 800e6, 449_950_000, 0, 350_050_000, keeper);
        vm.prank(keeper);
        g.resolveLate(3, m[0]);
        assertEq(uint8(g.memberInfo(1).status), uint8(RoscaGroup.Status.Defaulted));
        assertEq(g.memberInfo(1).holdback, 0);
        assertEq(g.memberInfo(1).deposit, 0);
        assertEq(g.claimable(keeper), BOUNTY);
        // round 3 already settled -> its arrears (100) paid first to recipient slot 3; remainder to coverage pool
        assertEq(g.coveragePool(), 449_950_000 - 100e6);
        // round 3: funded pot 800 - holdback 350 = 450 payout, + 100 arrears
        assertEq(g.memberInfo(3).claimable, 550e6);
    }

    function test_Waterfall_CoverageSharedOverRemainingRounds() public {
        RoscaGroup g = _s1UntilDefaultReady();
        vm.prank(keeper);
        g.resolveLate(3, m[0]);
        uint256 pool = g.coveragePool();
        vm.warp(g.quoteDue(4));
        // round 4: 7 non-defaulted recipients remain (slots 4..10); covShare = pool / 7
        uint256 share = pool / 7;
        for (uint256 i = 1; i < 9; ++i) {
            if (i == 3) continue;
            vm.prank(m[i]);
            g.pay(4, m[i], 100e6);
        }
        vm.expectEmit(true, true, false, true, address(g));
        emit RoundSettled(4, m[3], 900e6, share, 300e6, 500e6 + share);
        vm.prank(m[9]);
        g.pay(4, m[9], 100e6);
        assertEq(g.coveragePool(), pool - share);
    }

    function test_Waterfall_DefaultedMemberCannotActAfterwards() public {
        RoscaGroup g = _s1UntilDefaultReady();
        vm.prank(keeper);
        g.resolveLate(3, m[0]);
        vm.warp(g.quoteDue(4));
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.InvalidMember.selector);
        g.pay(4, m[0], 100e6);
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.InvalidMember.selector);
        g.topUpDeposit(1);
        vm.expectRevert(RoscaGroup.InvalidMember.selector);
        g.resolveLate(4, m[0]);
    }

    function test_Waterfall_ReserveCoversShortfallWithinCaps() public {
        // rho > 0: reserve may fund up to 50% of itself, never refundable (unsettled-round) rho
        RoscaGroup g = activeGroup(terms(5, 100e6, 5000, 110e6, 10e6));
        uint8[] memory p = allPay(5);
        p[0] = 1;
        for (uint8 t = 1; t <= 3; ++t) {
            vm.warp(g.quoteDue(t));
            for (uint256 i; i < 5; ++i) {
                if (i == t - 1 || !isActive(g, i) || t > p[i]) continue;
                vm.prank(m[i]);
                g.pay(t, m[i], 110e6);
            }
            vm.warp(g.quoteDue(t) + GRACE + CURE);
            g.sync();
            if (t == 2) {
                vm.prank(keeper);
                g.resolveLate(2, m[0]);
            }
        }
        // slot 1: holdback after round 1 = min(ceil(.5*100*4)=200, funded 400) = 200; deposit 0 after cure
        assertEq(g.memberInfo(1).holdback, 200e6);
        assertEq(g.memberInfo(1).deposit, 0);
        uint256 res = g.reserve();
        uint256 refundable = g.refundableRho();
        uint256 u = 100e6 + 200e6; // round 3 c + rounds 4,5
        uint256 seized = 200e6 - BOUNTY;
        uint256 expectUse = _min(u - seized, _min(res / 2, res - refundable));
        assertGt(expectUse, 0, "scenario must exercise the reserve");
        vm.expectEmit(true, true, false, true, address(g));
        emit Defaulted(m[0], 3, u, seized, expectUse, u - seized - expectUse, keeper);
        vm.prank(keeper);
        g.resolveLate(3, m[0]);
        assertEq(g.reserve(), res - expectUse);
        assertLe(expectUse, res / 2, "per-event cap 50%");
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }

    // ---------- S2 ----------
    function test_S2_ThreeDefaultersProgressiveHoldbackRelease() public {
        RoscaGroup g = activeGroup(baseTerms());
        uint8[] memory p = allPay(10);
        p[0] = 3; p[1] = 3; p[2] = 3;
        runStops(g, p);
        uint256 loss = uint256(_loss(3, 9)); // slots 4..10
        // oracle: total 750e6 (600e6 would mean holdback was NOT released progressively); + 3 bounties
        assertApproxEqAbs(loss - 3 * BOUNTY, 750e6, 10);
        assertTrue(loss - 3 * BOUNTY != 600e6);
        // oracle average 107.142857e6 per victim
        assertApproxEqAbs((loss - 3 * BOUNTY) / 7, 107_142_857, 2);
        assertEq(usdc.balanceOf(keeper), 3 * BOUNTY);
        assertEq(_sumAll(g, 10), 0);
        for (uint256 i; i < 3; ++i) {
            assertTrue(registry.isBanned(m[i]));
            assertEq(netOf(i), 250e6, "defaulters keep pot net of their forfeited collateral");
        }
        // arrears priority: slots 4,5 (settled before declaration) are made whole; slots 6-10 share the loss
        assertEq(netOf(3), 0);
        assertEq(netOf(4), 0);
        for (uint256 i = 5; i < 10; ++i) assertApproxEqAbs(netOf(i), -150_030_000, 1);
    }

    function test_S2_HoldbackReleasedByInstallmentsBeforeDefault() public {
        RoscaGroup g = activeGroup(baseTerms());
        // run rounds 1..3 with everyone paying; slot 1 holdback 450 - 2*50, slot 2 400 - 50, slot 3 350
        for (uint8 t = 1; t <= 3; ++t) {
            vm.warp(g.quoteDue(t));
            payRound(g, t);
        }
        assertEq(g.memberInfo(1).holdback, 350e6);
        assertEq(g.memberInfo(2).holdback, 350e6);
        assertEq(g.memberInfo(3).holdback, 350e6);
    }

    // ---------- S4: slot quits before its turn ----------
    function test_S4_SkippedRoundWhenSlotQuitsBeforeItsTurn() public {
        RoscaGroup g = activeGroup(baseTerms());
        uint8[] memory p = allPay(10);
        p[9] = 5; // slot 10 pays rounds 1-5 then stops
        vm.recordLogs();
        runStops(g, p);
        assertTrue(_hasLog(vm.getRecordedLogs(), RoundSkipped.selector, address(g), 10));
        assertTrue(g.roundSettled(10));
        assertTrue(g.roundSkipped(10));
        assertEq(uint8(g.memberInfo(10).status), uint8(RoscaGroup.Status.Defaulted));
        // oracle S4: slots 1-5 +100, slot 10 -500 (-600 incl. forfeited deposit), group nets to zero
        for (uint256 i; i < 5; ++i) assertEq(netOf(i), 100e6);
        assertEq(netOf(9), -600e6);
        assertEq(netOf(5) + netOf(6) + netOf(7) + netOf(8), 100e6, "oracle: slots 6-9 share +100 (4 x 25)");
        assertEq(_sumAll(g, 10), 0);
        // unrecovered 300 -> banned
        assertEq(registry.openUnrecovered(m[9]), 300e6);
        assertTrue(registry.isBanned(m[9]));
    }

    function test_SkippedRoundTakesNoPayments() public {
        RoscaGroup g = activeGroup(baseTerms());
        uint8[] memory p = allPay(10);
        p[9] = 5;
        runStops(g, p);
        RoscaGroup.RoundView memory r = g.roundInfo(10);
        assertTrue(r.skipped);
        for (uint256 i; i < 10; ++i) assertEq(r.principalPaid[i], 0);
        assertEq(g.memberInfo(10).claimable, 0);
    }

    // ---------- registry ban vs no ban ----------
    function test_NoBanWhenUnrecoveredIsZero() public {
        // d = 150: slot 1 pays rounds 2..8, cures round 9 from deposit (150->50), default at round 10 fully
        // covered by holdback(100)+deposit(50) after the bounty.
        RoscaGroup g = activeGroup(terms(10, 100e6, 5000, 150e6, 0));
        uint8[] memory p = allPay(10);
        p[0] = 8;
        runStops(g, p);
        assertEq(registry.defaultCount(m[0]), 1, "default counted");
        assertEq(registry.openUnrecovered(m[0]), 0);
        assertFalse(registry.isBanned(m[0]), "no ban when unrecovered is 0");
        assertEq(netOf(0), -int256(BOUNTY), "only the declare bounty is lost; excess collateral returned");
        for (uint256 i = 1; i < 10; ++i) assertEq(netOf(i), 0, "victims fully recovered");
        // can join a new group
        RoscaGroup g2 = newGroup(_fresh());
        vm.prank(m[0]);
        g2.accept(noAtt());
    }

    function test_DefaultExcessCollateralReturnedEvent() public {
        RoscaGroup g = activeGroup(terms(10, 100e6, 5000, 150e6, 0));
        for (uint8 t = 1; t <= 8; ++t) {
            vm.warp(g.quoteDue(t));
            payRound(g, t);
        }
        // round 9 and 10: slot 1 silent
        vm.warp(g.quoteDue(9));
        for (uint256 i = 1; i < 10; ++i) {
            if (i == 8) continue;
            vm.prank(m[i]);
            g.pay(9, m[i], 100e6);
        }
        vm.warp(g.quoteDue(9) + GRACE + CURE);
        g.resolveLate(9, m[0]);
        vm.warp(g.quoteDue(10));
        for (uint256 i = 1; i < 9; ++i) {
            vm.prank(m[i]);
            g.pay(10, m[i], 100e6);
        }
        vm.warp(g.quoteDue(10) + GRACE + CURE);
        // collateral = holdback 100 + deposit 50 = 150; bounty .05; U = 100 -> seized 100, excess 49.95
        vm.expectEmit(true, false, false, true, address(g));
        emit CollateralReturned(m[0], 49_950_000);
        vm.expectEmit(true, true, false, true, address(g));
        emit Defaulted(m[0], 10, 100e6, 100e6, 0, 0, keeper);
        vm.prank(keeper);
        g.resolveLate(10, m[0]);
    }

    // ---------- registry failure never blocks a default ----------
    function test_RegistryWriteFailureDoesNotBlockDefault() public {
        RevertingRegistry bad = new RevertingRegistry();
        Terms memory t = baseTerms();
        RoscaGroup g = RoscaGroup(Clones.clone(address(impl)));
        g.initialize(t, address(bad), address(0), creator);
        for (uint256 i; i < 10; ++i) {
            usdc.mint(m[i], START_BAL);
            vm.startPrank(m[i]);
            usdc.approve(address(g), type(uint256).max);
            g.accept(noAtt());
            vm.stopPrank();
        }
        startGroup(g);
        uint8[] memory p = allPay(10);
        p[0] = 1;
        vm.recordLogs();
        runStops(g, p);
        assertTrue(_hasLog(vm.getRecordedLogs(), RegistryWriteFailed.selector, address(g), uint256(uint160(m[0]))));
        assertEq(uint8(g.memberInfo(1).status), uint8(RoscaGroup.Status.Defaulted));
        assertEq(uint8(g.state()), uint8(RoscaGroup.State.Closed));
    }
}
