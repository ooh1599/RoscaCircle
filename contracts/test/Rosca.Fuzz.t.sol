// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RoscaBase} from "./Rosca.Base.t.sol";
import {RoscaGroup} from "../RoscaGroup.sol";
import {GroupFactory} from "../GroupFactory.sol";
import {Terms} from "../IRosca.sol";

contract RoscaFuzzTest is RoscaBase {
    /// Full participation is zero-sum: every member gets back exactly what it paid (deposit, holdback, rho),
    /// and only rounding dust may stay in the group.
    function testFuzz_FullPaymentIsZeroSum(uint8 nSeed, uint256 cSeed, uint16 phiSeed, uint256 rhoSeed) public {
        uint8 n = uint8(bound(nSeed, 4, 10));
        uint256 c = bound(cSeed, 1e6, 1_000_000_000);
        uint16 phi = uint16(bound(phiSeed, 3000, 10_000));
        uint256 rho = bound(rhoSeed, 0, c / 10);
        RoscaGroup g = activeGroup(terms(n, c, phi, c + rho, rho));
        runStops(g, allPay(n));
        assertEq(uint8(g.state()), uint8(RoscaGroup.State.Closed));
        for (uint256 i; i < n; ++i) assertApproxEqAbs(netOf(i), 0, 1);
        assertEq(usdc.balanceOf(address(g)), g.dust());
        assertLe(g.dust(), n);
        assertEq(g.reserve(), 0);
        assertEq(g.coveragePool(), 0);
    }

    /// Holdback target at receipt equals ceil(phi*c*(n-t)/BPS) and never exceeds the pot a recipient can fund.
    function testFuzz_HoldbackAtReceiptMatchesFormula(uint8 nSeed, uint256 cSeed, uint16 phiSeed) public {
        uint8 n = uint8(bound(nSeed, 4, 10));
        uint256 c = bound(cSeed, 1e6, 1_000_000_000);
        uint16 phi = uint16(bound(phiSeed, 3000, 10_000));
        RoscaGroup g = newGroup(terms(n, c, phi, c, 0));
        for (uint8 t = 1; t <= n; ++t) {
            uint256 num = uint256(phi) * c * (n - t);
            uint256 expected = num / 10_000 + (num % 10_000 == 0 ? 0 : 1);
            assertEq(g.hbAtReceipt(t), expected);
            assertLe(g.hbAtReceipt(t), (n - 1) * c);
        }
        assertEq(g.relPerInst(), (uint256(phi) * c + 9_999) / 10_000);
    }

    /// Any pattern of stopping members: nothing is created or lost, all USDC ends with someone entitled to it.
    function testFuzz_ArbitraryStopsConserveFunds(uint8 nSeed, uint16 phiSeed, uint256 rhoSeed, uint256 stopSeed)
        public
    {
        uint8 n = uint8(bound(nSeed, 4, 10));
        uint16 phi = uint16(bound(phiSeed, 3000, 10_000));
        uint256 rho = bound(rhoSeed, 0, 10e6);
        RoscaGroup g = activeGroup(terms(n, 100e6, phi, 100e6 + rho, rho));
        uint8[] memory p = new uint8[](n);
        for (uint256 i; i < n; ++i) p[i] = uint8(bound(uint256(keccak256(abi.encode(stopSeed, i))), 0, n));
        runStops(g, p);
        assertEq(uint8(g.state()), uint8(RoscaGroup.State.Closed));
        int256 sum = int256(usdc.balanceOf(keeper)) + int256(usdc.balanceOf(address(g)));
        for (uint256 i; i < n; ++i) sum += netOf(i);
        assertEq(sum, 0, "conservation");
        assertEq(usdc.balanceOf(address(g)), g.dust(), "only dust left after every claim");
        uint256 active;
        for (uint8 s = 1; s <= n; ++s) if (g.memberInfo(s).status == RoscaGroup.Status.Active) ++active;
        if (active != 0) assertLe(g.dust(), 10);
        // no member ever has claimable left behind
        for (uint8 s = 1; s <= n; ++s) assertEq(g.memberInfo(s).claimable, 0);
    }

    /// A defaulter never loses more than its remaining obligation + bounty beyond collateral (seizure <= U):
    /// its net is always >= -(bounty) when its own recovery was covered, and the registry only bans on a real loss.
    function testFuzz_BanIffUnrecoveredLoss(uint8 stopAfter, uint256 dSeed) public {
        uint8 stop = uint8(bound(stopAfter, 1, 9));
        uint256 d = bound(dSeed, 100e6, 400e6);
        RoscaGroup g = activeGroup(terms(10, 100e6, 5000, d, 0));
        uint8[] memory p = allPay(10);
        p[0] = stop;
        runStops(g, p);
        uint256 open = registry.openUnrecovered(m[0]);
        assertEq(registry.isBanned(m[0]), open > 0);
        if (open == 0) {
            // fully covered by collateral: defaulter loses at most the 0.05 bounty
            // (when it did default; it may instead have been cured from deposit throughout)
            assertGe(netOf(0), -int256(50_000));
        }
        // victims never gain more than they are owed: nobody ends above the defaulter's pot netting
        for (uint256 i = 1; i < 10; ++i) assertLe(netOf(i), 0);
    }

    // ---------- gate score boundary ----------
    function testFuzz_GateScoreMustExceedFloor(uint32 score) public view {
        bytes32 th = keccak256("terms");
        uint64 exp = uint64(block.timestamp + 1 days);
        bool ok = gate.verify(m[0], th, score, exp, 1, signAtt(attesterPk, m[0], th, score, exp, 1).sig);
        assertEq(ok, score > 20_000);
    }

    // ---------- factory floors ----------
    function testFuzz_FactoryRejectsCOutOfRange(uint256 cSeed) public {
        uint256 c = bound(cSeed, 0, type(uint128).max);
        vm.assume(c < 1e6 || c > 1_000_000_000);
        Terms memory t = terms(10, c, 5000, c, 0);
        vm.prank(creator);
        vm.expectRevert(GroupFactory.InvalidTerms.selector);
        factory.createGroup(t);
    }

    function testFuzz_FactoryRejectsLowPhi(uint16 phiSeed) public {
        uint16 phi = uint16(bound(phiSeed, 0, 2999));
        Terms memory t = terms(10, 100e6, phi, 100e6, 0);
        vm.prank(creator);
        vm.expectRevert(GroupFactory.InvalidTerms.selector);
        factory.createGroup(t);
    }

    function testFuzz_FactoryRejectsRhoAboveTenPercent(uint256 rhoSeed) public {
        uint256 rho = bound(rhoSeed, 10e6 + 1, 100e6);
        Terms memory t = terms(10, 100e6, 5000, 100e6 + rho, rho);
        vm.prank(creator);
        vm.expectRevert(GroupFactory.InvalidTerms.selector);
        factory.createGroup(t);
    }
}
