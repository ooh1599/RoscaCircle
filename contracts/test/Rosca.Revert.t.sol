// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {RoscaBase} from "./Rosca.Base.t.sol";
import {RoscaGroup} from "../RoscaGroup.sol";
import {Terms, Attestation} from "../IRosca.sol";

contract RoscaRevertTest is RoscaBase {
    event DepositToppedUp(address indexed member, uint256 amount);
    event LateCured(uint8 indexed round, address indexed member, uint256 amount);
    event Payment(uint8 indexed round, address indexed member, address indexed payer, uint256 rhoPart, uint256 cPart, bool fromDeposit);
    event AttestationUsed(address indexed member, uint256 nonce);
    event Claimed(address indexed wallet, uint256 amount);

    // ---------- pay / collect ----------
    function test_PayBeforeActivationReverts() public {
        RoscaGroup g = newGroup(baseTerms());
        acceptAll(g);
        vm.prank(m[1]);
        vm.expectRevert(RoscaGroup.InvalidState.selector);
        g.pay(1, m[1], 100e6);
        vm.expectRevert(RoscaGroup.InvalidState.selector);
        g.collect(1, m[1]);
    }

    function test_PayRevertPaths() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.startPrank(m[1]);
        vm.expectRevert(RoscaGroup.InvalidRound.selector);
        g.pay(0, m[1], 1);
        vm.expectRevert(RoscaGroup.InvalidRound.selector);
        g.pay(11, m[1], 1);
        vm.expectRevert(RoscaGroup.InvalidMember.selector); // m[1] is round 2's own recipient
        g.pay(2, m[1], 1);
        vm.stopPrank();
        vm.warp(g.quoteDue(1));
        vm.expectRevert(RoscaGroup.InvalidMember.selector); // recipient owes nothing in own round
        g.pay(1, m[0], 1);
        vm.expectRevert(RoscaGroup.InvalidMember.selector); // not a member
        g.pay(1, makeAddr("x"), 1);
        vm.expectRevert(RoscaGroup.TooEarly.selector); // round 2 not yet due
        g.pay(2, m[2], 1);
        vm.expectRevert(RoscaGroup.InvalidRound.selector);
        g.collect(0, m[2]);
    }

    function test_PayZeroAmountIsNoOp() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.warp(g.quoteDue(1));
        vm.prank(m[1]);
        g.pay(1, m[1], 0);
        assertEq(g.paidC(1, 1), 0);
    }

    function test_PayAfterRoundSettledIsArrearsToRecipient() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.warp(g.quoteDue(1));
        for (uint256 i = 2; i < 10; ++i) {
            vm.prank(m[i]);
            g.pay(1, m[i], 100e6);
        }
        vm.warp(g.quoteDue(1) + GRACE);
        g.sync();
        assertTrue(g.roundSettled(1));
        uint256 before = g.memberInfo(1).claimable;
        vm.prank(m[1]);
        g.pay(1, m[1], 100e6); // late but within cure window
        assertEq(g.memberInfo(1).claimable, before + 100e6, "late c goes straight to recipient");
    }

    // ---------- resolveLate ----------
    function _slot3MissesRound1() internal returns (RoscaGroup g) {
        g = activeGroup(baseTerms());
        vm.warp(g.quoteDue(1));
        for (uint256 i = 1; i < 10; ++i) {
            if (i == 2) continue;
            vm.prank(m[i]);
            g.pay(1, m[i], 100e6);
        }
    }

    function test_ResolveLateTooEarly() public {
        RoscaGroup g = _slot3MissesRound1();
        vm.warp(g.quoteDue(1) + GRACE + CURE - 1);
        vm.expectRevert(RoscaGroup.TooEarly.selector);
        g.resolveLate(1, m[2]);
    }

    function test_ResolveLateNothingMissingAndInvalid() public {
        RoscaGroup g = _slot3MissesRound1();
        vm.warp(g.quoteDue(1) + GRACE + CURE);
        vm.expectRevert(RoscaGroup.NothingMissing.selector);
        g.resolveLate(1, m[3]);
        vm.expectRevert(RoscaGroup.InvalidMember.selector);
        g.resolveLate(1, m[0]); // recipient
    }

    function test_ResolveLateCuresFromDeposit() public {
        RoscaGroup g = _slot3MissesRound1();
        vm.warp(g.quoteDue(1) + GRACE + CURE);
        uint256 hbBefore = g.memberInfo(3).holdback;
        vm.expectEmit(true, true, true, true, address(g));
        emit Payment(1, m[2], m[2], 0, 100e6, true);
        vm.expectEmit(true, true, false, true, address(g));
        emit LateCured(1, m[2], 100e6);
        vm.prank(keeper);
        g.resolveLate(1, m[2]);
        RoscaGroup.MemberView memory mv = g.memberInfo(3);
        assertEq(mv.deposit, 0);
        assertEq(mv.depositUses, 1);
        assertEq(uint8(mv.status), uint8(RoscaGroup.Status.Active));
        assertTrue(g.depositCured(1, 2));
        assertEq(mv.holdback, hbBefore, "no holdback change on cure");
        // round 1 settled at grace with 8 payers: 800 funded; hb 450; payout 350; cure arrears +100
        assertEq(g.memberInfo(1).claimable, 450e6);
        assertEq(g.memberInfo(1).holdback, 450e6);
    }

    function test_TopUpDepositAfterCure() public {
        RoscaGroup g = _slot3MissesRound1();
        vm.warp(g.quoteDue(1) + GRACE + CURE);
        g.resolveLate(1, m[2]);
        vm.expectEmit(true, false, false, true, address(g));
        emit DepositToppedUp(m[2], 100e6);
        vm.prank(m[2]);
        g.topUpDeposit(500e6); // capped at d - deposit
        assertEq(g.memberInfo(3).deposit, 100e6);
        vm.prank(m[2]);
        g.topUpDeposit(1); // already full: no-op
        assertEq(g.memberInfo(3).deposit, 100e6);
    }

    function test_TopUpRevertPaths() public {
        RoscaGroup g = newGroup(baseTerms());
        acceptAll(g);
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.InvalidState.selector);
        g.topUpDeposit(1);
        startGroup(g);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(RoscaGroup.InvalidMember.selector);
        g.topUpDeposit(1);
    }

    function test_CureDoesNotReleaseHoldbackLater() public {
        // slot 1 (holdback 450) cures round 2 from deposit then tops up and pays round 3 in wallet: release is
        // only blocked for the cured installment itself.
        RoscaGroup g = activeGroup(baseTerms());
        vm.warp(g.quoteDue(1));
        payRound(g, 1);
        vm.warp(g.quoteDue(2));
        for (uint256 i = 2; i < 10; ++i) {
            vm.prank(m[i]);
            g.pay(2, m[i], 100e6);
        }
        vm.warp(g.quoteDue(2) + GRACE + CURE);
        g.resolveLate(2, m[0]);
        assertEq(g.memberInfo(1).holdback, 450e6, "no release on cure");
        // paying the cured installment again is capped to zero: nothing left, no release
        vm.prank(m[0]);
        g.pay(2, m[0], 100e6);
        assertEq(g.memberInfo(1).holdback, 450e6);
        // round 3 in wallet while deposit is not full: no release
        vm.warp(g.quoteDue(3));
        vm.prank(m[0]);
        g.pay(3, m[0], 100e6);
        assertEq(g.memberInfo(1).holdback, 450e6, "deposit below d blocks release");
        vm.prank(m[0]);
        g.topUpDeposit(100e6);
        vm.warp(g.quoteDue(4));
        vm.prank(m[0]);
        g.pay(4, m[0], 100e6);
        assertEq(g.memberInfo(1).holdback, 400e6, "release resumes once deposit restored");
    }

    function test_EarlierInstallmentPendingBlocksLaterResolve() public {
        RoscaGroup g = activeGroup(baseTerms());
        // slot 1 pays nothing in rounds 2 and 3 (after receiving round 1)
        vm.warp(g.quoteDue(1));
        payRound(g, 1);
        vm.warp(g.quoteDue(3) + GRACE + CURE);
        vm.expectRevert(abi.encodeWithSelector(RoscaGroup.EarlierInstallmentPending.selector, uint8(2)));
        g.resolveLate(3, m[0]);
    }

    // ---------- finalize / claim ----------
    function test_FinalizeBeforeAllRoundsReverts() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.expectRevert(RoscaGroup.InvalidState.selector);
        g.finalize();
        vm.warp(g.quoteDue(1));
        payRound(g, 1);
        vm.expectRevert(RoscaGroup.InvalidState.selector);
        g.finalize();
    }

    function test_FinalizeRevertsWhilePendingResolution() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.warp(g.quoteDue(10) + GRACE);
        g.sync();
        assertEq(g.nextRound(), 11);
        vm.expectRevert(RoscaGroup.PendingResolution.selector);
        g.finalize();
    }

    function test_FinalizeTwiceReverts() public {
        RoscaGroup g = activeGroup(baseTerms());
        for (uint8 r = 1; r <= 10; ++r) {
            vm.warp(g.quoteDue(r));
            payRound(g, r);
        }
        g.finalize();
        vm.expectRevert(RoscaGroup.InvalidState.selector);
        g.finalize();
    }

    function test_ClaimZeroIsNoOpAndDoubleClaimPaysOnce() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.prank(m[0]);
        g.claim(); // nothing claimable
        for (uint8 r = 1; r <= 10; ++r) {
            vm.warp(g.quoteDue(r));
            payRound(g, r);
        }
        g.finalize();
        vm.expectEmit(true, false, false, true, address(g));
        emit Claimed(m[0], 1000e6);
        vm.prank(m[0]);
        g.claim();
        uint256 b = usdc.balanceOf(m[0]);
        vm.prank(m[0]);
        g.claim();
        assertEq(usdc.balanceOf(m[0]), b);
        assertEq(g.claimable(m[0]), 0);
    }

    // ---------- views ----------
    function test_ViewsAndInvalidInputs() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.expectRevert(RoscaGroup.InvalidSlot.selector);
        g.memberInfo(0);
        vm.expectRevert(RoscaGroup.InvalidSlot.selector);
        g.memberInfo(11);
        vm.expectRevert(RoscaGroup.InvalidRound.selector);
        g.roundInfo(0);
        vm.expectRevert(RoscaGroup.InvalidRound.selector);
        g.quoteDue(11);
        vm.expectRevert(RoscaGroup.InvalidRound.selector);
        g.roundReady(0);
        vm.expectRevert(RoscaGroup.InvalidRound.selector);
        g.hbAtReceipt(11);
        vm.expectRevert(RoscaGroup.InvalidSlot.selector);
        g.requiresAttestation(0);
        assertFalse(g.requiresAttestation(1));
        assertEq(g.quoteDue(1), g.getTerms().startTime);
        assertEq(g.quoteDue(3), uint256(g.getTerms().startTime) + 2 * PERIOD);
        assertEq(g.roundInfo(3).recipient, m[2]);
        assertEq(g.slotOf(m[4]), 5);
        assertEq(g.hbAtReceipt(1), 450e6);
        assertEq(g.hbAtReceipt(10), 0);
    }

    function test_RoundInfoReflectsPayments() public {
        RoscaGroup g = activeGroup(baseTerms());
        vm.warp(g.quoteDue(1));
        vm.prank(m[5]);
        g.pay(1, m[5], 100e6);
        RoscaGroup.RoundView memory r = g.roundInfo(1);
        assertEq(r.principalPaid[5], 100e6);
        assertFalse(r.settled);
        assertFalse(r.ready);
        assertEq(r.principalPaid.length, 10);
    }

    // ---------- passport gate inside the group ----------
    function _gated(uint32 minScore) internal returns (RoscaGroup g) {
        Terms memory t = baseTerms();
        t.useGate = true;
        t.minScoreMilli = minScore;
        t.ungatedCap = 100e6;
        g = newGroup(t);
    }

    function _att(RoscaGroup g, address w, uint32 score, uint64 exp, uint256 nonce) internal view returns (Attestation memory) {
        return signAtt(attesterPk, w, g.termsHash(), score, exp, nonce);
    }

    function test_GatedSlotsMarkedPerSpec() public {
        RoscaGroup g = _gated(30_000);
        // exposure = 350,300,250,200,150,100,50,0,0,0 vs cap 100 -> slots 1..5 over cap, then slot 6 (largest) to fit
        for (uint8 s = 1; s <= 6; ++s) assertTrue(g.requiresAttestation(s), "gated");
        for (uint8 s = 7; s <= 10; ++s) assertFalse(g.requiresAttestation(s), "ungated");
    }

    function test_GatedAcceptValidAttestation() public {
        RoscaGroup g = _gated(30_000);
        Attestation memory a = _att(g, m[0], 30_001, uint64(block.timestamp + 1 days), 1);
        vm.expectEmit(true, false, false, true, address(g));
        emit AttestationUsed(m[0], 1);
        vm.prank(m[0]);
        g.accept(a);
        assertEq(uint8(g.memberInfo(1).status), uint8(RoscaGroup.Status.Accepted));
        assertTrue(g.usedNonce(keccak256(abi.encode(m[0], uint256(1)))));
        // an ungated slot needs no attestation
        vm.prank(m[9]);
        g.accept(noAtt());
        assertEq(g.acceptedCount(), 2);
    }

    function test_GatedAcceptMissingAttestationReverts() public {
        RoscaGroup g = _gated(30_000);
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.InvalidAttestation.selector);
        g.accept(noAtt());
    }

    function test_GatedAcceptWrongSignerReverts() public {
        RoscaGroup g = _gated(30_000);
        (, uint256 evilPk) = makeAddrAndKey("evil");
        Attestation memory a = signAtt(evilPk, m[0], g.termsHash(), 40_000, uint64(block.timestamp + 1 days), 1);
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.InvalidAttestation.selector);
        g.accept(a);
    }

    function test_GatedAcceptExpiredReverts() public {
        RoscaGroup g = _gated(30_000);
        uint64 exp = uint64(block.timestamp + 100);
        Attestation memory a = _att(g, m[0], 40_000, exp, 1);
        vm.warp(exp + 1);
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.InvalidAttestation.selector);
        g.accept(a);
    }

    function test_GatedAcceptWrongWalletOrOtherGroupReverts() public {
        RoscaGroup g = _gated(30_000);
        RoscaGroup g2 = _gated(30_000);
        Attestation memory forOther = _att(g, m[1], 40_000, uint64(block.timestamp + 1 days), 1);
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.InvalidAttestation.selector);
        g.accept(forOther);
        Attestation memory forG2 = _att(g2, m[0], 40_000, uint64(block.timestamp + 1 days), 1);
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.InvalidAttestation.selector); // bound to termsHash (per-clone)
        g.accept(forG2);
    }

    function test_GatedReplayedNonceReverts() public {
        RoscaGroup g = _gated(30_000);
        Attestation memory a = _att(g, m[0], 40_000, uint64(block.timestamp + 1 days), 9);
        vm.prank(m[0]);
        g.accept(a);
        vm.prank(m[0]);
        g.withdraw();
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.NonceUsed.selector);
        g.accept(a);
        // a fresh nonce works
        Attestation memory fresh = _att(g, m[0], 40_000, uint64(block.timestamp + 1 days), 10);
        vm.prank(m[0]);
        g.accept(fresh);
        assertEq(g.acceptedCount(), 1);
    }

    function test_GatedScoreExactlyMinScoreFails() public {
        RoscaGroup g = _gated(30_000);
        Attestation memory a = _att(g, m[0], 30_000, uint64(block.timestamp + 1 days), 1);
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.InvalidAttestation.selector);
        g.accept(a);
    }

    function test_GatedScoreExactlyFloor20000Fails() public {
        RoscaGroup g = _gated(20_000); // minimum configurable score
        Attestation memory bad = _att(g, m[0], 20_000, uint64(block.timestamp + 1 days), 1);
        Attestation memory good = _att(g, m[0], 20_001, uint64(block.timestamp + 1 days), 2);
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.InvalidAttestation.selector);
        g.accept(bad);
        vm.prank(m[0]);
        g.accept(good);
        assertEq(g.acceptedCount(), 1);
    }

    function test_GatedGroupWithoutGateAddressRejectsGatedSlots() public {
        // the factory forbids this configuration, so initialize a clone directly
        Terms memory t = baseTerms();
        t.useGate = true;
        t.minScoreMilli = 30_000;
        t.ungatedCap = 100e6;
        RoscaGroup g = RoscaGroup(Clones.clone(address(impl)));
        g.initialize(t, address(registry), address(0), creator);
        for (uint256 i; i < 10; ++i) {
            usdc.mint(m[i], START_BAL);
            vm.prank(m[i]);
            usdc.approve(address(g), type(uint256).max);
        }
        vm.prank(m[0]);
        vm.expectRevert(RoscaGroup.InvalidAttestation.selector);
        g.accept(Attestation(40_000, uint64(block.timestamp + 1 days), 1, hex""));
    }

    function test_InitializeRejectsBadTermsDirectly() public {
        Terms memory t = baseTerms();
        RoscaGroup g = RoscaGroup(Clones.clone(address(impl)));
        vm.expectRevert(RoscaGroup.InvalidTerms.selector);
        g.initialize(t, address(0), address(0), creator);
        t.n = 3;
        vm.expectRevert(RoscaGroup.InvalidTerms.selector);
        g.initialize(t, address(registry), address(0), creator);
    }
}
