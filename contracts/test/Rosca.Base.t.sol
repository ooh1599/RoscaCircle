// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {RoscaGroup} from "../RoscaGroup.sol";
import {GroupFactory} from "../GroupFactory.sol";
import {PassportGate} from "../PassportGate.sol";
import {DefaultRegistry} from "../DefaultRegistry.sol";
import {Terms, Attestation} from "../IRosca.sol";

abstract contract RoscaBase is Test {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    uint256 internal constant START_BAL = 1_000_000e6;
    uint64 internal constant PERIOD = 7 days;
    uint64 internal constant GRACE = 1 days;
    uint64 internal constant CURE = 1 days;

    MockERC20 internal usdc;
    RoscaGroup internal impl;
    PassportGate internal gate;
    GroupFactory internal factory;
    DefaultRegistry internal registry;

    address internal admin = makeAddr("admin");
    address internal creator = makeAddr("creator");
    address internal keeper = makeAddr("keeper");
    address internal attester;
    uint256 internal attesterPk;
    address[] internal m;
    uint256[] internal bal0;
    uint64 internal t0;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        t0 = uint64(block.timestamp);
        MockERC20 mock = new MockERC20("Mock USDC", "USDC", 6);
        vm.etch(USDC, address(mock).code);
        usdc = MockERC20(USDC);
        (attester, attesterPk) = makeAddrAndKey("attester");
        for (uint256 i; i < 10; ++i) m.push(makeAddr(string.concat("member", vm.toString(i))));
        impl = new RoscaGroup();
        gate = new PassportGate(attester);
        factory = new GroupFactory(admin, address(impl), address(gate), 3000, 10_000, 1e6, 1_000_000_000, 31_536_000);
        registry = factory.registry();
    }

    // ---------- builders ----------
    function terms(uint8 n, uint256 c, uint16 phi, uint256 d, uint256 rho) internal view returns (Terms memory t) {
        t.n = n;
        t.c = c;
        t.phiBps = phi;
        t.d = d;
        t.rho = rho;
        t.startTime = t0 + 3 days;
        t.period = PERIOD;
        t.grace = GRACE;
        t.cure = CURE;
        t.acceptDeadline = t0 + 3 days - 1 hours;
        t.members = new address[](n);
        for (uint256 i; i < n; ++i) t.members[i] = m[i];
    }

    function baseTerms() internal view returns (Terms memory) {
        return terms(10, 100e6, 5000, 100e6, 0);
    }

    function newGroup(Terms memory t) internal returns (RoscaGroup g) {
        vm.prank(creator);
        g = RoscaGroup(factory.createGroup(t));
        for (uint256 i; i < t.n; ++i) {
            usdc.mint(m[i], START_BAL);
            vm.prank(m[i]);
            usdc.approve(address(g), type(uint256).max);
        }
    }

    function noAtt() internal pure returns (Attestation memory a) {}

    function acceptAll(RoscaGroup g) internal {
        uint8 n = g.getTerms().n;
        for (uint256 i; i < n; ++i) {
            vm.prank(m[i]);
            g.accept(noAtt());
        }
    }

    function startGroup(RoscaGroup g) internal {
        vm.warp(g.getTerms().startTime);
        g.sync();
    }

    function activeGroup(Terms memory t) internal returns (RoscaGroup g) {
        g = newGroup(t);
        snap(t.n);
        acceptAll(g);
        startGroup(g);
    }

    function snap(uint256 n) internal {
        delete bal0;
        for (uint256 i; i < n; ++i) bal0.push(usdc.balanceOf(m[i]));
    }

    function netOf(uint256 i) internal view returns (int256) {
        return int256(usdc.balanceOf(m[i])) - int256(bal0[i]);
    }

    function isActive(RoscaGroup g, uint256 i) internal view returns (bool) {
        return g.memberInfo(uint8(i + 1)).status == RoscaGroup.Status.Active;
    }

    function payRound(RoscaGroup g, uint8 t) internal {
        uint256 inst = g.inst();
        uint8 n = g.getTerms().n;
        for (uint256 i; i < n; ++i) {
            if (i == t - 1 || !isActive(g, i)) continue;
            vm.prank(m[i]);
            g.pay(t, m[i], inst);
        }
    }

    function claimAll(RoscaGroup g) internal {
        uint8 n = g.getTerms().n;
        for (uint256 i; i < n; ++i) {
            vm.prank(m[i]);
            g.claim();
        }
        vm.prank(keeper);
        g.claim();
    }

    /// @dev Drive a whole group: member i (0-based) pays installments only for rounds t <= paysUntil[i];
    /// afterwards the keeper resolves every unpaid installment (cure from deposit, else default).
    function runStops(RoscaGroup g, uint8[] memory paysUntil) internal {
        uint8 n = g.getTerms().n;
        uint256 inst = g.inst();
        for (uint8 t = 1; t <= n; ++t) {
            vm.warp(g.quoteDue(t));
            if (!_recipientForfeited(g, t)) {
                for (uint256 i; i < n; ++i) {
                    if (i == t - 1 || !isActive(g, i) || t > paysUntil[i]) continue;
                    vm.prank(m[i]);
                    g.pay(t, m[i], inst);
                }
            }
            vm.warp(g.quoteDue(t) + GRACE + CURE);
            g.sync();
            if (_recipientForfeited(g, t)) continue;
            for (uint256 i; i < n; ++i) {
                if (i == t - 1 || !isActive(g, i)) continue;
                RoscaGroup.RoundView memory r = g.roundInfo(t);
                if (r.principalPaid[i] + r.reservePaid[i] >= inst) continue;
                vm.prank(keeper);
                g.resolveLate(t, m[i]);
            }
        }
        vm.warp(g.quoteDue(n) + GRACE + CURE + 1);
        g.sync();
        g.finalize();
        claimAll(g);
    }

    function _recipientForfeited(RoscaGroup g, uint8 t) internal view returns (bool) {
        return g.memberInfo(t).status == RoscaGroup.Status.Defaulted;
    }

    function allPay(uint8 n) internal pure returns (uint8[] memory a) {
        a = new uint8[](n);
        for (uint256 i; i < n; ++i) a[i] = n;
    }

    // ---------- attestation signing ----------
    function signAtt(uint256 pk, address wallet, bytes32 termsHash, uint32 score, uint64 exp, uint256 nonce)
        internal view returns (Attestation memory a)
    {
        bytes32 ds = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("RoscaPassportGate"), keccak256("1"), block.chainid, address(gate)
        ));
        bytes32 sh = keccak256(abi.encode(gate.HUMAN_ATTESTATION_TYPEHASH(), wallet, termsHash, score, exp, nonce));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", ds, sh)));
        a = Attestation(score, exp, nonce, abi.encodePacked(r, s, v));
    }
}
