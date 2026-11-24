// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RoscaBase} from "./Rosca.Base.t.sol";
import {RoscaGroup} from "../RoscaGroup.sol";

/// @dev Regression tests for hbShortfall tracking: late principal for a settled round first refills the
/// recipient's holdback shortfall, only the remainder becomes claimable.
/// Scenario terms: n=10, c=100e6, phiBps=5000, d=100e6, rho=0 => hbAtReceipt(1) = 450e6.
contract RoscaShortfallTest is RoscaBase {
    uint256 internal constant C = 100e6;
    uint256 internal constant HB1 = 450e6; // ceil(100e6 * 5000 * 9 / 10000)

    event RoundSettled(uint8 indexed round, address indexed recipient, uint256 collected, uint256 covShare, uint256 hb, uint256 payout);

    /// Round 1: the first `early` other members pay in full at due; then grace elapses and the round settles.
    function _settleRound1(uint256 early) internal returns (RoscaGroup g) {
        g = activeGroup(baseTerms());
        vm.warp(g.quoteDue(1));
        for (uint256 k = 1; k <= early; ++k) {
            vm.prank(m[k]);
            g.pay(1, m[k], C);
        }
        vm.warp(g.quoteDue(1) + GRACE);
        g.sync();
        assertTrue(g.roundSettled(1), "round 1 settled at grace end");
    }

    function _latePay(RoscaGroup g, uint256 k, uint256 amt) internal {
        vm.prank(m[k]);
        g.pay(1, m[k], amt);
    }

    // ---------- view ----------
    function test_ShortfallOf_InvalidRoundReverts() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.expectRevert(RoscaGroup.InvalidRound.selector);
        g.hbShortfallOf(0);
        vm.expectRevert(RoscaGroup.InvalidRound.selector);
        g.hbShortfallOf(11);
    }

    function test_ShortfallOf_ZeroBeforeSettlement() public {
        RoscaGroup g = activeGroup(baseTerms());
        for (uint8 t = 1; t <= 10; ++t) assertEq(g.hbShortfallOf(t), 0);
    }

    function test_ShortfallOf_ZeroWhenPotCoversHoldback() public {
        RoscaGroup g = _settleRound1(9);
        assertEq(g.hbShortfallOf(1), 0);
        assertEq(g.memberInfo(1).holdback, HB1);
    }

    // ---------- (1) nobody pays before grace ends ----------
    /// @dev Round 1 settles with only the recipient's own netted installment. That c was never transferred in,
    /// so the funded pot is 0: hb = 0 (NOT 100e6 as a pot-including-own-c model would give) and the whole
    /// 450e6 target is the shortfall. Counting own c would create an unbacked holdback (insolvency).
    function test_NobodyPays_RoundSettlesWithZeroFundedHoldbackAndFullShortfall() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.warp(g.quoteDue(1) + GRACE);
        vm.expectEmit(true, true, false, true, address(g));
        emit RoundSettled(1, m[0], C, 0, 0, 0);
        g.sync();
        assertEq(g.hbShortfallOf(1), HB1);
        assertEq(g.memberInfo(1).holdback, 0);
        assertEq(g.memberInfo(1).claimable, 0);
    }

    function test_NobodyPays_AllLatePrincipalRefillsHoldbackThenClaimable() public {
        RoscaGroup g = _settleRound1(0);
        uint256 paid;
        for (uint256 k = 1; k <= 9; ++k) {
            _latePay(g, k, C);
            paid += C;
            RoscaGroup.MemberView memory mv = g.memberInfo(1);
            uint256 expHb = paid < HB1 ? paid : HB1;
            assertEq(mv.holdback, expHb, "holdback refilled first");
            assertEq(mv.claimable, paid - expHb, "claimable only gets the remainder");
            assertEq(g.hbShortfallOf(1), HB1 - expHb, "shortfall tracks the unfilled target");
            assertLe(mv.holdback, g.hbAtReceipt(1), "holdback never above target");
            // never more than cash received minus holdback
            assertLe(mv.claimable, paid - mv.holdback);
        }
        assertEq(g.memberInfo(1).holdback, 450e6, "holdback ends at 450e6");
        assertEq(g.memberInfo(1).claimable, 450e6, "claimable gets only the remainder");
        assertEq(g.hbShortfallOf(1), 0);
        // contract holds deposits (10 * d) + all late principal
        assertEq(usdc.balanceOf(address(g)), 10 * 100e6 + 900e6);
    }

    /// @dev The 4th late payment straddles the boundary: 50e6 completes the refill and 50e6 is claimable.
    function test_NobodyPays_StraddlingPaymentSplitsExactly() public {
        RoscaGroup g = _settleRound1(0);
        for (uint256 k = 1; k <= 4; ++k) _latePay(g, k, C); // 400e6 => holdback 400, shortfall 50
        assertEq(g.memberInfo(1).holdback, 400e6);
        assertEq(g.hbShortfallOf(1), 50e6);
        assertEq(g.memberInfo(1).claimable, 0);
        _latePay(g, 5, C);
        assertEq(g.memberInfo(1).holdback, 450e6);
        assertEq(g.memberInfo(1).claimable, 50e6);
        assertEq(g.hbShortfallOf(1), 0);
    }

    function test_NobodyPays_RecipientClaimsOnlyRemainder() public {
        RoscaGroup g = _settleRound1(0);
        for (uint256 k = 1; k <= 9; ++k) _latePay(g, k, C);
        uint256 before = usdc.balanceOf(m[0]);
        vm.prank(m[0]);
        g.claim();
        assertEq(usdc.balanceOf(m[0]) - before, 450e6, "claim never exceeds pot minus holdback");
        assertEq(g.memberInfo(1).holdback, 450e6);
    }

    /// @dev Variant: one member pays before grace => funded pot 100e6 => hb 100e6, shortfall 350e6.
    function test_OneEarlyPayer_HoldbackHundredShortfallThreeFifty() public {
        RoscaGroup g = _settleRound1(1);
        assertEq(g.memberInfo(1).holdback, 100e6);
        assertEq(g.memberInfo(1).claimable, 0);
        assertEq(g.hbShortfallOf(1), 350e6);
        for (uint256 k = 2; k <= 9; ++k) _latePay(g, k, C); // 800e6 late
        assertEq(g.memberInfo(1).holdback, 450e6);
        assertEq(g.memberInfo(1).claimable, 450e6);
        assertEq(g.hbShortfallOf(1), 0);
    }

    /// @dev Partial late payments: split holds payment by payment and nothing is lost to rounding.
    function test_PartialLatePaymentsRefillInOrder() public {
        RoscaGroup g = _settleRound1(0);
        _latePay(g, 1, 30e6);
        assertEq(g.memberInfo(1).holdback, 30e6);
        assertEq(g.hbShortfallOf(1), 420e6);
        _latePay(g, 1, 70e6);
        assertEq(g.memberInfo(1).holdback, 100e6);
        assertEq(g.memberInfo(1).claimable, 0);
    }

    function test_ReleaseDoesNotReopenShortfall() public {
        RoscaGroup g = _settleRound1(0);
        for (uint256 k = 1; k <= 9; ++k) _latePay(g, k, C);
        vm.warp(g.quoteDue(2));
        vm.prank(m[0]);
        g.pay(2, m[0], C); // full wallet installment releases relPerInst = 50e6 of holdback
        assertEq(g.memberInfo(1).holdback, 400e6);
        assertEq(g.hbShortfallOf(1), 0, "release must not re-open the shortfall");
    }

    // ---------- (2) recipient defaulted => all late principal to claimable ----------
    /// @dev m[0] receives round 1 (settled with `early` payers), then misses rounds 2 and 3: round 2 is cured
    /// from deposit, round 3 defaults (deposit exhausted). Returns the group right after the default.
    function _defaultRecipientOne(uint256 early, uint256 latePayers) internal returns (RoscaGroup g) {
        g = _settleRound1(early);
        for (uint256 k = early + 1; k <= early + latePayers; ++k) _latePay(g, k, C);
        for (uint8 t = 2; t <= 3; ++t) {
            vm.warp(g.quoteDue(t));
            for (uint256 i = 1; i < 10; ++i) {
                if (i == t - 1) continue;
                vm.prank(m[i]);
                g.pay(t, m[i], C);
            }
            vm.warp(g.quoteDue(t) + GRACE + CURE);
            g.sync();
            vm.prank(keeper);
            g.resolveLate(t, m[0]);
        }
        assertEq(uint8(g.memberInfo(1).status), uint8(RoscaGroup.Status.Defaulted), "recipient defaulted");
    }

    function test_DefaultedRecipient_AllLatePrincipalToClaimable() public {
        RoscaGroup g = _defaultRecipientOne(0, 0);
        assertEq(g.hbShortfallOf(1), HB1, "shortfall untouched by default");
        assertEq(g.memberInfo(1).holdback, 0);
        uint256 claimBefore = g.memberInfo(1).claimable;
        for (uint256 k = 1; k <= 9; ++k) {
            _latePay(g, k, C);
            assertEq(g.memberInfo(1).claimable, claimBefore + k * C, "every late c goes to claimable");
            assertEq(g.memberInfo(1).holdback, 0, "defaulted recipient holdback never refilled");
            assertEq(g.hbShortfallOf(1), HB1, "defaulted recipient shortfall not funded");
        }
    }

    function test_DefaultedRecipient_PartiallyRefilledShortfallStaysFrozen() public {
        RoscaGroup g = _defaultRecipientOne(0, 2); // 200e6 refilled before default
        assertEq(g.hbShortfallOf(1), 250e6, "remaining shortfall frozen at default");
        assertEq(g.memberInfo(1).holdback, 0, "holdback seized/zeroed by default");
        uint256 claimBefore = g.memberInfo(1).claimable;
        for (uint256 k = 3; k <= 9; ++k) _latePay(g, k, C);
        assertEq(g.memberInfo(1).claimable, claimBefore + 7 * C);
        assertEq(g.memberInfo(1).holdback, 0);
        assertEq(g.hbShortfallOf(1), 250e6);
    }

    // ---------- (3) fuzz: conservation ----------
    /// @dev Random number of early payers and random (possibly partial) late payments in random member order.
    /// After every payment: cash-in == holdback + claimable, shortfall == target - holdback, and claimable is
    /// only non-zero once the shortfall is fully refilled; the contract balance equals deposits + principal in.
    function testFuzz_LatePrincipalConservation(uint8 early, uint96[9] memory amts, uint8 rot) public {
        early = uint8(bound(early, 0, 9));
        RoscaGroup g = _settleRound1(early);
        uint256 inflow = uint256(early) * C; // others' principal actually transferred in
        for (uint256 pass; pass < 2; ++pass) {
            for (uint256 j; j < 9; ++j) {
                uint256 k = 1 + ((j + rot) % 9);
                uint256 amt = pass == 0 ? bound(amts[j], 0, C) : C; // second pass tops everyone up
                uint256 remaining = C - g.paidC(1, k);
                uint256 eff = amt < remaining ? amt : remaining;
                _latePay(g, k, amt);
                inflow += eff;
                _checkConservation(g, inflow);
            }
        }
        assertEq(g.memberInfo(1).holdback, HB1);
        assertEq(g.memberInfo(1).claimable, 450e6);
        assertEq(g.hbShortfallOf(1), 0);
    }

    function _checkConservation(RoscaGroup g, uint256 inflow) internal view {
        RoscaGroup.MemberView memory mv = g.memberInfo(1);
        assertEq(mv.holdback + mv.claimable, inflow, "recipient buckets == principal in");
        assertEq(mv.holdback + g.hbShortfallOf(1), HB1, "holdback + shortfall == target");
        if (mv.claimable != 0) assertEq(g.hbShortfallOf(1), 0, "claimable only after refill");
        assertLe(mv.claimable, inflow - mv.holdback);
        assertEq(usdc.balanceOf(address(g)), 10 * 100e6 + inflow, "balance == deposits + principal in");
    }
}
