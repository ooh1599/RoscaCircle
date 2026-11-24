// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {RoscaBase} from "./Rosca.Base.t.sol";
import {RoscaGroup} from "../RoscaGroup.sol";
import {GroupFactory} from "../GroupFactory.sol";
import {PassportGate} from "../PassportGate.sol";
import {DefaultRegistry} from "../DefaultRegistry.sol";
import {Terms} from "../IRosca.sol";

contract RoscaFactoryTest is RoscaBase {
    event GroupCreated(address indexed group, address indexed creator, bytes32 termsHash);
    event AdminTransferStarted(address indexed admin, address indexed pendingAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    // ---------- constructor ----------
    function test_FactoryConstructorState() public view {
        assertEq(factory.admin(), admin);
        assertEq(factory.implementation(), address(impl));
        assertEq(factory.gate(), address(gate));
        assertEq(factory.minPhiBps(), 3000);
        assertEq(factory.minDepositBps(), 10_000);
        assertEq(factory.minC(), 1e6);
        assertEq(factory.maxC(), 1_000_000_000);
        assertEq(factory.maxDuration(), 31_536_000);
        assertEq(registry.factory(), address(factory));
        assertEq(factory.groupCount(), 0);
    }

    function test_FactoryConstructorRevertsOnBadConfig() public {
        address i = address(impl);
        address g = address(gate);
        vm.expectRevert(GroupFactory.InvalidConfiguration.selector);
        new GroupFactory(address(0), i, g, 3000, 10_000, 1e6, 1e9, 31_536_000);
        vm.expectRevert(GroupFactory.InvalidConfiguration.selector);
        new GroupFactory(admin, address(0xBEEF), g, 3000, 10_000, 1e6, 1e9, 31_536_000);
        vm.expectRevert(GroupFactory.InvalidConfiguration.selector);
        new GroupFactory(admin, i, g, 10_001, 10_000, 1e6, 1e9, 31_536_000);
        vm.expectRevert(GroupFactory.InvalidConfiguration.selector);
        new GroupFactory(admin, i, g, 3000, 10_000, 0, 1e9, 31_536_000);
        vm.expectRevert(GroupFactory.InvalidConfiguration.selector);
        new GroupFactory(admin, i, g, 3000, 10_000, 2e6, 1e6, 31_536_000);
        vm.expectRevert(GroupFactory.InvalidConfiguration.selector);
        new GroupFactory(admin, i, g, 3000, 10_000, 1e6, 1e9, 3 hours);
    }

    function test_RegistryConstructorRejectsZeroFactory() public {
        vm.expectRevert(DefaultRegistry.InvalidFactory.selector);
        new DefaultRegistry(address(0));
    }

    // ---------- createGroup ----------
    function test_CreateGroupHappyPathAndEvent() public {
        Terms memory t = baseTerms();
        vm.prank(creator);
        vm.recordLogs();
        address g = factory.createGroup(t);
        assertTrue(factory.isGroup(g));
        assertEq(factory.groups(0), g);
        assertEq(factory.groupCount(), 1);
        RoscaGroup grp = RoscaGroup(g);
        assertEq(grp.creator(), creator);
        assertEq(grp.registry(), address(registry));
        assertEq(grp.gate(), address(gate));
        assertEq(grp.inst(), 100e6);
        assertEq(grp.relPerInst(), 50e6);
        assertEq(uint8(grp.state()), uint8(RoscaGroup.State.Recruiting));
        assertEq(grp.termsHash(), keccak256(abi.encode(block.chainid, g, t)));
    }

    function test_CreateGroupEmitsGroupCreated() public {
        Terms memory t = baseTerms();
        // address of the next clone is unknown; check topic0 + creator only (topic1 unchecked).
        vm.expectEmit(false, true, false, false, address(factory));
        emit GroupCreated(address(0), creator, bytes32(0));
        vm.prank(creator);
        factory.createGroup(t);
    }

    function test_ImplementationCannotBeInitialized() public {
        Terms memory t = baseTerms();
        vm.expectRevert();
        impl.initialize(t, address(registry), address(0), creator);
    }

    function test_CloneCannotBeReinitialized() public {
        Terms memory t = baseTerms();
        RoscaGroup g = newGroup(t);
        vm.expectRevert();
        g.initialize(t, address(registry), address(0), creator);
    }

    function _expectInvalidTerms(Terms memory t) internal {
        vm.prank(creator);
        vm.expectRevert(GroupFactory.InvalidTerms.selector);
        factory.createGroup(t);
    }

    function test_FloorN() public {
        Terms memory t = terms(10, 100e6, 5000, 100e6, 0);
        t.n = 3;
        _expectInvalidTerms(t);
        t.n = 11;
        _expectInvalidTerms(t);
        t = baseTerms();
        t.n = 9; // members length mismatch
        _expectInvalidTerms(t);
    }

    function test_FloorC() public {
        _expectInvalidTerms(terms(10, 1e6 - 1, 5000, 1e6, 0));
        _expectInvalidTerms(terms(10, 1_000_000_001, 5000, 1_000_000_001, 0));
        // boundaries accepted
        vm.prank(creator);
        factory.createGroup(terms(10, 1e6, 5000, 1e6, 0));
        vm.prank(creator);
        factory.createGroup(terms(10, 1_000_000_000, 5000, 1_000_000_000, 0));
    }

    function test_FloorPhi() public {
        _expectInvalidTerms(terms(10, 100e6, 2999, 100e6, 0));
        _expectInvalidTerms(terms(10, 100e6, 10_001, 100e6, 0));
        vm.prank(creator);
        factory.createGroup(terms(10, 100e6, 3000, 100e6, 0));
        vm.prank(creator);
        factory.createGroup(terms(10, 100e6, 10_000, 100e6, 0));
    }

    function test_FloorRhoAndDeposit() public {
        _expectInvalidTerms(terms(10, 100e6, 5000, 111e6, 10e6 + 1)); // rho > c/10
        _expectInvalidTerms(terms(10, 100e6, 5000, 99e6, 0)); // d < c
        _expectInvalidTerms(terms(10, 100e6, 5000, 105e6, 10e6)); // d < c + rho
        vm.prank(creator);
        factory.createGroup(terms(10, 100e6, 5000, 110e6, 10e6));
    }

    function test_FloorTimes() public {
        Terms memory t = baseTerms();
        t.period = 1 hours - 1;
        _expectInvalidTerms(t);
        t = baseTerms();
        t.grace = 1 hours - 1;
        _expectInvalidTerms(t);
        t.grace = 14 days + 1;
        _expectInvalidTerms(t);
        t = baseTerms();
        t.cure = 1 hours - 1;
        _expectInvalidTerms(t);
        t.cure = 7 days + 1;
        _expectInvalidTerms(t);
        t = baseTerms();
        t.period = uint64(31_536_000 / 10 + 1); // n * period > maxDuration
        _expectInvalidTerms(t);
        t = baseTerms();
        t.startTime = uint64(block.timestamp);
        t.acceptDeadline = uint64(block.timestamp);
        _expectInvalidTerms(t);
        t = baseTerms();
        t.acceptDeadline = uint64(block.timestamp);
        _expectInvalidTerms(t);
        t = baseTerms();
        t.acceptDeadline = t.startTime + 1;
        _expectInvalidTerms(t);
    }

    function test_GateTermsRules() public {
        Terms memory t = baseTerms();
        t.useGate = true;
        t.minScoreMilli = 19_999;
        _expectInvalidTerms(t);
        t = baseTerms();
        t.minScoreMilli = 30_000; // not gated but score set
        _expectInvalidTerms(t);
        t = baseTerms();
        t.useGate = true;
        t.minScoreMilli = 20_000; // exactly the floor is a valid configuration
        vm.prank(creator);
        factory.createGroup(t);
    }

    function test_GateRequiresGateAddress() public {
        GroupFactory f = new GroupFactory(admin, address(impl), address(0), 3000, 10_000, 1e6, 1e9, 31_536_000);
        Terms memory t = baseTerms();
        t.useGate = true;
        t.minScoreMilli = 30_000;
        vm.expectRevert(GroupFactory.InvalidTerms.selector);
        f.createGroup(t);
    }

    function test_ZeroAndDuplicateMembers() public {
        Terms memory t = baseTerms();
        t.members[3] = address(0);
        vm.prank(creator);
        vm.expectRevert(GroupFactory.InvalidMember.selector);
        factory.createGroup(t);
        t = baseTerms();
        t.members[5] = t.members[1];
        vm.prank(creator);
        vm.expectRevert(GroupFactory.InvalidMember.selector);
        factory.createGroup(t);
    }

    // ---------- admin ----------
    function test_AdminPausesAndUnpausesCreationOnly() public {
        vm.prank(admin);
        factory.pauseCreation();
        assertTrue(factory.paused());
        vm.prank(creator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.createGroup(baseTerms());
        vm.prank(admin);
        factory.unpauseCreation();
        vm.prank(creator);
        factory.createGroup(baseTerms());
    }

    function test_PauseDoesNotAffectExistingGroups() public {
        RoscaGroup g = newGroup(baseTerms());
        vm.prank(admin);
        factory.pauseCreation();
        acceptAll(g);
        assertEq(uint8(g.state()), uint8(RoscaGroup.State.Locked));
        startGroup(g);
        payRound(g, 1);
        assertTrue(g.roundSettled(1));
    }

    function test_NonAdminCannotAdminister() public {
        address bob = makeAddr("bob");
        vm.startPrank(bob);
        vm.expectRevert(GroupFactory.Unauthorized.selector);
        factory.pauseCreation();
        vm.expectRevert(GroupFactory.Unauthorized.selector);
        factory.unpauseCreation();
        vm.expectRevert(GroupFactory.Unauthorized.selector);
        factory.transferAdmin(bob);
        vm.stopPrank();
    }

    function test_TwoStepAdminTransfer() public {
        address next = makeAddr("next");
        vm.expectEmit(true, true, false, false, address(factory));
        emit AdminTransferStarted(admin, next);
        vm.prank(admin);
        factory.transferAdmin(next);
        assertEq(factory.admin(), admin);
        assertEq(factory.pendingAdmin(), next);
        // incumbent retains authority, pending cannot act until accept
        vm.prank(next);
        vm.expectRevert(GroupFactory.Unauthorized.selector);
        factory.pauseCreation();
        vm.expectEmit(true, true, false, false, address(factory));
        emit AdminTransferred(admin, next);
        vm.prank(next);
        factory.acceptAdmin();
        assertEq(factory.admin(), next);
        assertEq(factory.pendingAdmin(), address(0));
        vm.prank(admin);
        vm.expectRevert(GroupFactory.Unauthorized.selector);
        factory.pauseCreation();
        vm.prank(next);
        factory.pauseCreation();
    }

    function test_TransferAdminRejectsZeroAndWrongAcceptor() public {
        vm.prank(admin);
        vm.expectRevert(GroupFactory.InvalidConfiguration.selector);
        factory.transferAdmin(address(0));
        vm.prank(admin);
        factory.transferAdmin(makeAddr("next"));
        vm.prank(makeAddr("other"));
        vm.expectRevert(GroupFactory.Unauthorized.selector);
        factory.acceptAdmin();
    }

    // ---------- registry auth ----------
    function test_RegistryRejectsNonGroupWriters() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(DefaultRegistry.UnauthorizedGroup.selector);
        registry.record(m[0], rando, 100, false);
        // even a real group address cannot be spoofed by an outsider
        RoscaGroup g = newGroup(baseTerms());
        vm.prank(rando);
        vm.expectRevert(DefaultRegistry.UnauthorizedGroup.selector);
        registry.record(m[0], address(g), 100, false);
        assertFalse(registry.isBanned(m[0]));
    }

    function test_RegistryRejectsGroupFromOtherFactory() public {
        GroupFactory other = new GroupFactory(admin, address(impl), address(gate), 3000, 10_000, 1e6, 1e9, 31_536_000);
        vm.prank(creator);
        address foreign = other.createGroup(baseTerms());
        vm.prank(foreign);
        vm.expectRevert(DefaultRegistry.UnauthorizedGroup.selector);
        registry.record(m[0], foreign, 100, false);
    }

    function test_RegistryRecordFromRealGroup() public {
        RoscaGroup g = newGroup(baseTerms());
        vm.expectEmit(true, true, false, true, address(registry));
        emit DefaultRegistry.DefaultRecorded(m[0], address(g), 500, false);
        vm.prank(address(g));
        registry.record(m[0], address(g), 500, false);
        assertEq(registry.defaultCount(m[0]), 1);
        assertEq(registry.openUnrecovered(m[0]), 500);
        assertTrue(registry.isBanned(m[0]));
    }

    function test_RegistryZeroUnrecoveredIsNotBannedButCounted() public {
        RoscaGroup g = newGroup(baseTerms());
        vm.prank(address(g));
        registry.record(m[0], address(g), 0, false);
        assertEq(registry.defaultCount(m[0]), 1);
        assertFalse(registry.isBanned(m[0]));
    }

    function test_RegistryIssuerBlockedNeverBans() public {
        RoscaGroup g = newGroup(baseTerms());
        vm.prank(address(g));
        registry.record(m[0], address(g), 900e6, true);
        assertEq(registry.blockedCount(m[0]), 1);
        assertEq(registry.openUnrecovered(m[0]), 0);
        assertFalse(registry.isBanned(m[0]));
    }

    // ---------- gate ----------
    function test_GateConstructorRejectsZeroAttester() public {
        vm.expectRevert(PassportGate.InvalidAttester.selector);
        new PassportGate(address(0));
    }

    function test_GateVerifyValid() public view {
        bytes32 th = keccak256("terms");
        assertTrue(_verify(attesterPk, m[0], th, 20_001, uint64(block.timestamp + 1 days), 7));
    }

    function test_GateVerifyScoreExactlyFloorFails() public view {
        bytes32 th = keccak256("terms");
        assertFalse(_verify(attesterPk, m[0], th, 20_000, uint64(block.timestamp + 1 days), 7));
        assertFalse(_verify(attesterPk, m[0], th, 0, uint64(block.timestamp + 1 days), 7));
    }

    function test_GateVerifyWrongSigner() public {
        (, uint256 otherPk) = makeAddrAndKey("evil");
        assertFalse(_verify(otherPk, m[0], keccak256("t"), 50_000, uint64(block.timestamp + 1 days), 1));
    }

    function test_GateVerifyExpiry() public {
        bytes32 th = keccak256("t");
        uint64 exp = uint64(block.timestamp + 100);
        assertTrue(_verify(attesterPk, m[0], th, 50_000, exp, 1));
        vm.warp(exp); // expiresAt == now still valid
        assertTrue(_verify(attesterPk, m[0], th, 50_000, exp, 1));
        vm.warp(exp + 1);
        assertFalse(_verify(attesterPk, m[0], th, 50_000, exp, 1));
    }

    function test_GateVerifyBoundToFields() public view {
        bytes32 th = keccak256("t");
        uint64 exp = uint64(block.timestamp + 1 days);
        bytes memory sig = signAtt(attesterPk, m[0], th, 50_000, exp, 1).sig;
        assertTrue(gate.verify(m[0], th, 50_000, exp, 1, sig));
        assertFalse(gate.verify(m[1], th, 50_000, exp, 1, sig)); // other wallet
        assertFalse(gate.verify(m[0], keccak256("x"), 50_000, exp, 1, sig)); // other terms
        assertFalse(gate.verify(m[0], th, 50_001, exp, 1, sig)); // other score
        assertFalse(gate.verify(m[0], th, 50_000, exp, 2, sig)); // other nonce
    }

    function test_GateVerifyGarbageSignatureReturnsFalse() public view {
        assertFalse(gate.verify(m[0], bytes32(0), 50_000, uint64(block.timestamp + 1), 1, hex"1234"));
        assertFalse(gate.verify(m[0], bytes32(0), 50_000, uint64(block.timestamp + 1), 1, new bytes(65)));
    }

    function _verify(uint256 pk, address w, bytes32 th, uint32 score, uint64 exp, uint256 nonce)
        internal view returns (bool)
    {
        return gate.verify(w, th, score, exp, nonce, signAtt(pk, w, th, score, exp, nonce).sig);
    }
}
