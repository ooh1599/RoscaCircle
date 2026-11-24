// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RoscaBase} from "./Rosca.Base.t.sol";
import {RoscaGroup} from "../RoscaGroup.sol";
import {Terms, Attestation} from "../IRosca.sol";

contract RoscaGroupTest is RoscaBase {
    event Accepted(address indexed member, uint8 slot, uint256 deposit);
    event Locked();
    event Activated();
    event Cancelled();
    event DepositRefunded(address indexed member, uint256 amount);
    event Withdrawn(address indexed member, uint256 amount);
    event Payment(uint8 indexed round, address indexed member, address indexed payer, uint256 rhoPart, uint256 cPart, bool fromDeposit);
    event RoundSettled(uint8 indexed round, address indexed recipient, uint256 collected, uint256 covShare, uint256 hb, uint256 payout);
    event HoldbackReleased(address indexed member, uint8 indexed round, uint256 amount);
    event CollateralReturned(address indexed member, uint256 amount);
    event Closed(uint256 dust);
    event Claimed(address indexed wallet, uint256 amount);
    event CollectFailed(uint8 indexed round, address indexed member);

    // ---------- happy path ----------
    function test_FullHappyPathN10() public {
        Terms memory t = baseTerms();
        RoscaGroup g = newGroup(t);
        snap(10);
        for (uint256 i; i < 10; ++i) {
            vm.expectEmit(true, false, false, true, address(g));
            emit Accepted(m[i], uint8(i + 1), 100e6);
            vm.prank(m[i]);
            g.accept(noAtt());
        }
        assertEq(uint8(g.state()), uint8(RoscaGroup.State.Locked));
        assertEq(usdc.balanceOf(address(g)), 1000e6);

        vm.expectEmit(false, false, false, false, address(g));
        emit Activated();
        startGroup(g);
        assertEq(uint8(g.state()), uint8(RoscaGroup.State.Active));

        for (uint8 r = 1; r <= 10; ++r) {
            vm.warp(g.quoteDue(r));
            payRound(g, r);
            assertTrue(g.roundSettled(r), "round settled once all paid");
            assertEq(g.nextRound(), r + 1);
            RoscaGroup.MemberView memory rec = g.memberInfo(r);
            uint256 hb = 50e6 * (10 - r);
            // holdback at receipt, minus releases for installments paid after receipt (none for r itself)
            assertEq(rec.holdback, hb, "holdback = ceil(phi*c*(n-t))");
            assertEq(g.hbAtReceipt(r), hb);
        }
        // every member has been fully released along the way
        for (uint8 s = 1; s <= 10; ++s) {
            assertEq(g.memberInfo(s).holdback, 0, "holdback fully released");
            assertEq(g.memberInfo(s).claimable, 900e6, "pot net of holdback + released holdback = 900");
            assertEq(g.memberInfo(s).deposit, 100e6);
        }
        vm.expectEmit(false, false, false, true, address(g));
        emit Closed(0);
        g.finalize();
        assertEq(uint8(g.state()), uint8(RoscaGroup.State.Closed));
        for (uint256 i; i < 10; ++i) {
            vm.expectEmit(true, false, false, true, address(g));
            emit Claimed(m[i], 1000e6);
            vm.prank(m[i]);
            g.claim();
            assertEq(netOf(i), 0, "deposit + holdback returned: zero net");
        }
        assertEq(usdc.balanceOf(address(g)), 0);
        assertEq(g.dust(), 0);
        assertEq(g.reserve(), 0);
        assertEq(g.coveragePool(), 0);
    }

    function test_RoundSettledEventFirstRound() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.warp(g.quoteDue(1));
        for (uint256 i = 1; i < 9; ++i) {
            vm.prank(m[i]);
            g.pay(1, m[i], 100e6);
        }
        vm.expectEmit(true, true, false, true, address(g));
        emit RoundSettled(1, m[0], 1000e6, 0, 450e6, 450e6);
        vm.prank(m[9]);
        g.pay(1, m[9], 100e6);
        assertEq(g.memberInfo(1).claimable, 450e6);
    }

    function test_PaymentEventAndHoldbackReleasedEvent() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.warp(g.quoteDue(1));
        payRound(g, 1);
        vm.warp(g.quoteDue(2));
        vm.expectEmit(true, true, true, true, address(g));
        emit Payment(2, m[0], m[0], 0, 100e6, false);
        vm.expectEmit(true, true, false, true, address(g));
        emit HoldbackReleased(m[0], 2, 50e6);
        vm.prank(m[0]);
        g.pay(2, m[0], 100e6);
        assertEq(g.memberInfo(1).holdback, 400e6);
        assertEq(g.memberInfo(1).claimable, 500e6);
    }

    function test_RhoReserveAndPaysBack() public {
        // rho=10e6 -> inst=110e6, d=110e6; reserve is refunded pro-rata at finalize
        RoscaGroup g = activeGroup(terms(5, 100e6, 5000, 110e6, 10e6));
        for (uint8 r = 1; r <= 5; ++r) {
            vm.warp(g.quoteDue(r));
            payRound(g, r);
        }
        assertEq(g.reserve(), 5 * 5 * 10e6, "every member pays rho each round incl. netted own");
        g.finalize();
        claimAll(g);
        for (uint256 i; i < 5; ++i) assertEq(netOf(i), 0);
        assertEq(usdc.balanceOf(address(g)), g.dust());
    }

    function test_OverpayIsCapped() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.warp(g.quoteDue(1));
        uint256 before = usdc.balanceOf(m[1]);
        vm.prank(m[1]);
        g.pay(1, m[1], 500e6);
        assertEq(before - usdc.balanceOf(m[1]), 100e6);
        // fully paid: further pay is a no-op
        vm.prank(m[1]);
        g.pay(1, m[1], 5e6);
        assertEq(before - usdc.balanceOf(m[1]), 100e6);
    }

    function test_ThirdPartyCanPayForMember() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.warp(g.quoteDue(1));
        usdc.mint(keeper, 100e6);
        vm.prank(keeper);
        usdc.approve(address(g), type(uint256).max);
        vm.prank(keeper);
        g.pay(1, m[3], 100e6);
        assertEq(g.paidC(1, 3), 100e6);
    }

    function test_CollectPullsAllowance() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.warp(g.quoteDue(1));
        g.collect(1, m[2]);
        assertEq(g.paidC(1, 2), 100e6);
        g.collect(1, m[2]); // nothing remaining: no-op
        assertEq(g.paidC(1, 2), 100e6);
    }

    function test_CollectFailureEmitsAndDoesNotRevert() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.warp(g.quoteDue(1));
        vm.prank(m[2]);
        usdc.approve(address(g), 0);
        vm.expectEmit(true, true, false, false, address(g));
        emit CollectFailed(1, m[2]);
        g.collect(1, m[2]);
        assertEq(g.paidC(1, 2), 0);
    }

    function test_RoundSettlesByGraceWithoutAllPaid() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.warp(g.quoteDue(1));
        for (uint256 i = 1; i < 8; ++i) {
            vm.prank(m[i]);
            g.pay(1, m[i], 100e6);
        }
        assertFalse(g.roundReady(1));
        vm.warp(g.quoteDue(1) + GRACE);
        assertTrue(g.roundReady(1));
        g.sync();
        assertTrue(g.roundSettled(1));
        assertEq(g.memberInfo(1).holdback, 450e6, "funded pot 700 >= hbAtReceipt 450");
        assertEq(g.memberInfo(1).claimable, 250e6);
    }

    function test_HoldbackCappedByFundedPot() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.warp(g.quoteDue(1));
        for (uint256 i = 1; i < 3; ++i) {
            vm.prank(m[i]);
            g.pay(1, m[i], 100e6);
        }
        vm.warp(g.quoteDue(1) + GRACE);
        g.sync();
        // funded pot = 200 < hbAtReceipt 450 -> everything held back, payout 0
        assertEq(g.memberInfo(1).holdback, 200e6);
        assertEq(g.memberInfo(1).claimable, 0);
    }

    // ---------- recruiting ----------
    function test_AcceptRevertPaths() public {
        RoscaGroup g = newGroup(baseTerms());
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(RoscaGroup.InvalidMember.selector);
        g.accept(noAtt());

        vm.prank(m[0]);
        g.accept(noAtt());
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.InvalidMember.selector);
        g.accept(noAtt());

        // no allowance -> token revert
        address nobody = makeAddr("nobody");
        Terms memory t = baseTerms();
        t.members[1] = nobody;
        RoscaGroup g2 = newGroup(t);
        vm.prank(nobody);
        vm.expectRevert();
        g2.accept(noAtt());
    }

    function test_AcceptAfterDeadlineReverts() public {
        RoscaGroup g = newGroup(baseTerms());
        vm.warp(g.getTerms().acceptDeadline + 1);
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.DeadlinePassed.selector);
        g.accept(noAtt());
    }

    function test_AcceptAtDeadlineAllowed() public {
        RoscaGroup g = newGroup(baseTerms());
        vm.warp(g.getTerms().acceptDeadline);
        vm.prank(m[0]);
        g.accept(noAtt());
        assertEq(g.acceptedCount(), 1);
    }

    function test_AcceptWhenLockedReverts() public {
        RoscaGroup g = newGroup(baseTerms());
        acceptAll(g);
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.InvalidState.selector); // group is Locked
        g.accept(noAtt());
    }

    function test_AcceptFeeOnTransferReverts() public {
        RoscaGroup g = newGroup(baseTerms());
        usdc.setFeeBps(100);
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.InsufficientReceived.selector);
        g.accept(noAtt());
    }

    function test_PositiveTransferSurplusIsTrackedAsDust() public {
        RoscaGroup g = newGroup(baseTerms());
        usdc.setBonus(7);
        vm.prank(m[0]);
        g.accept(noAtt());
        assertEq(g.dust(), 7);
        assertEq(g.memberInfo(1).deposit, 100e6, "obligation sized by d, not by received");
    }

    function test_LockedEventOnLastAccept() public {
        RoscaGroup g = newGroup(baseTerms());
        for (uint256 i; i < 9; ++i) {
            vm.prank(m[i]);
            g.accept(noAtt());
        }
        vm.expectEmit(false, false, false, false, address(g));
        emit Locked();
        vm.prank(m[9]);
        g.accept(noAtt());
    }

    function test_WithdrawWhileRecruiting() public {
        RoscaGroup g = newGroup(baseTerms());
        vm.prank(m[0]);
        g.accept(noAtt());
        vm.expectEmit(true, false, false, true, address(g));
        emit Withdrawn(m[0], 100e6);
        vm.prank(m[0]);
        g.withdraw();
        assertEq(g.acceptedCount(), 0);
        assertEq(g.memberInfo(1).claimable, 100e6);
        assertEq(uint8(g.memberInfo(1).status), uint8(RoscaGroup.Status.None));
        vm.prank(m[0]);
        g.claim();
        assertEq(usdc.balanceOf(address(g)), 0);
        // can re-accept after withdrawing
        vm.prank(m[0]);
        g.accept(noAtt());
        assertEq(g.acceptedCount(), 1);
    }

    function test_WithdrawRevertsForNonAcceptedAndWhenActive() public {
        RoscaGroup g = newGroup(baseTerms());
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.InvalidMember.selector);
        g.withdraw();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(RoscaGroup.InvalidMember.selector);
        g.withdraw();
        acceptAll(g);
        startGroup(g);
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.InvalidMember.selector); // Active, not Accepted: cannot leave
        g.withdraw();
    }

    function test_WithdrawWhileLockedCancelsGroupAndRefundsAll() public {
        RoscaGroup g = newGroup(baseTerms());
        acceptAll(g);
        vm.expectEmit(false, false, false, false, address(g));
        emit Cancelled();
        vm.prank(m[4]);
        g.withdraw();
        assertEq(uint8(g.state()), uint8(RoscaGroup.State.Cancelled));
        for (uint8 s = 1; s <= 10; ++s) assertEq(g.memberInfo(s).claimable, 100e6);
        assertEq(g.acceptedCount(), 0);
    }

    function test_CancelBeforeDeadlineReverts() public {
        RoscaGroup g = newGroup(baseTerms());
        vm.prank(m[0]);
        g.accept(noAtt());
        vm.expectRevert(RoscaGroup.InvalidState.selector);
        g.cancel();
    }

    function test_CancelAfterDeadlineRefunds() public {
        RoscaGroup g = newGroup(baseTerms());
        vm.prank(m[0]);
        g.accept(noAtt());
        vm.prank(m[1]);
        g.accept(noAtt());
        vm.warp(g.getTerms().acceptDeadline + 1);
        vm.expectEmit(true, false, false, true, address(g));
        emit DepositRefunded(m[0], 100e6);
        g.cancel();
        assertEq(uint8(g.state()), uint8(RoscaGroup.State.Cancelled));
        vm.prank(m[0]);
        g.claim();
        vm.prank(m[1]);
        g.claim();
        assertEq(usdc.balanceOf(address(g)), 0);
        // cancel again is a harmless no-op
        g.cancel();
    }

    function test_RecruitingGroupCancelledLazilyAtStart() public {
        RoscaGroup g = newGroup(baseTerms());
        vm.prank(m[0]);
        g.accept(noAtt());
        vm.warp(g.getTerms().startTime);
        g.sync();
        assertEq(uint8(g.state()), uint8(RoscaGroup.State.Cancelled));
        assertEq(g.memberInfo(1).claimable, 100e6);
    }

    function test_LockedGroupNeverStartedCancelsAfterOnePeriod() public {
        RoscaGroup g = newGroup(baseTerms());
        acceptAll(g);
        vm.warp(uint256(g.getTerms().startTime) + PERIOD);
        g.cancel();
        assertEq(uint8(g.state()), uint8(RoscaGroup.State.Cancelled));
        for (uint8 s = 1; s <= 10; ++s) assertEq(g.memberInfo(s).claimable, 100e6);
    }

    function test_LockedGroupBeforeTimeoutActivatesInsteadOfCancel() public {
        RoscaGroup g = newGroup(baseTerms());
        acceptAll(g);
        vm.warp(uint256(g.getTerms().startTime) + 1);
        vm.expectRevert(RoscaGroup.InvalidState.selector);
        g.cancel();
        assertEq(uint8(g.state()), uint8(RoscaGroup.State.Locked), "revert rolled back lazy activation");
    }
}
