// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentPay} from "../src/AgentPay.sol";
import {MockUSD8} from "../src/mocks/MockUSD8.sol";
import {Signing} from "./Signing.sol";

/// @notice Unit tests for AgentPay: every limit an agent could try to escape is a test here.
contract AgentPayTest is Test {
    MockUSD8 token;
    AgentPay agentPay;

    address payer;
    uint256 payerKey;
    address agent = makeAddr("agent");
    address merchant = makeAddr("merchant");
    address otherMerchant = makeAddr("other-merchant");
    address relayer = makeAddr("relayer");

    bytes32 constant SESSION = keccak256("session-1");
    bytes32 constant ORDER = keccak256("order-1");
    bytes32 constant ORDER2 = keccak256("order-2");

    uint256 constant BUDGET = 100e6;   // 100 tUSD8
    uint256 constant CAP = 20e6;       // 20 tUSD8 per payment
    uint64 expiry;

    function setUp() public {
        (payer, payerKey) = makeAddrAndKey("payer");
        token = new MockUSD8();
        agentPay = new AgentPay(IERC20(address(token)));
        expiry = uint64(block.timestamp + 7 days);
        token.mint(payer, 1_000e6);
        vm.prank(payer);
        token.approve(address(agentPay), type(uint256).max);
    }

    function _open() internal {
        vm.prank(payer);
        agentPay.openSession(SESSION, agent, BUDGET, CAP, expiry);
    }

    // ---------------------------------------------------------------- session

    function test_openSession_recordsLimitsAndEmits() public {
        vm.expectEmit(true, true, true, true, address(agentPay));
        emit AgentPay.SessionOpened(SESSION, payer, agent, BUDGET, CAP, expiry);
        _open();

        AgentPay.Session memory s = agentPay.sessionOf(SESSION);
        assertEq(s.payer, payer);
        assertEq(s.agent, agent);
        assertEq(s.budget, BUDGET);
        assertEq(s.perPaymentCap, CAP);
        assertEq(s.expiry, expiry);
        assertEq(s.spent, 0);
        assertFalse(s.revoked);
        assertTrue(s.exists);
        assertEq(agentPay.remaining(SESSION), BUDGET);
    }

    function test_openSession_rejectsDuplicate() public {
        _open();
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(AgentPay.SessionExists.selector, SESSION));
        agentPay.openSession(SESSION, agent, BUDGET, CAP, expiry);
    }

    function test_openSession_rejectsZeroBudgetOrCap() public {
        vm.startPrank(payer);
        vm.expectRevert(AgentPay.ZeroAmount.selector);
        agentPay.openSession(SESSION, agent, 0, CAP, expiry);
        vm.expectRevert(AgentPay.ZeroAmount.selector);
        agentPay.openSession(SESSION, agent, BUDGET, 0, expiry);
        vm.stopPrank();
    }

    function test_openSession_rejectsPastExpiry() public {
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(AgentPay.SessionExpired.selector, block.timestamp));
        agentPay.openSession(SESSION, agent, BUDGET, CAP, uint64(block.timestamp));
    }

    // ---------------------------------------------------------------- pay

    function test_pay_movesFundsAndChargesBudget() public {
        _open();
        vm.prank(agent);
        agentPay.pay(SESSION, ORDER, merchant, 5e6);

        assertEq(token.balanceOf(merchant), 5e6);
        assertEq(token.balanceOf(payer), 1_000e6 - 5e6);
        assertEq(token.balanceOf(address(agentPay)), 0, "contract must never hold funds");
        assertEq(agentPay.remaining(SESSION), BUDGET - 5e6);
        assertTrue(agentPay.isOrderPaid(SESSION, ORDER));
    }

    function test_pay_onlyAgentOrPayer() public {
        _open();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(AgentPay.NotAgent.selector);
        agentPay.pay(SESSION, ORDER, merchant, 1e6);
    }

    function test_pay_rejectsAbovePerPaymentCap() public {
        _open();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentPay.PerPaymentCapExceeded.selector, CAP, CAP + 1));
        agentPay.pay(SESSION, ORDER, merchant, CAP + 1);
    }

    function test_pay_rejectsAboveBudgetAfterSeveralPayments() public {
        _open();
        // 5 payments of 20 = 100 = budget; the 6th must fail on budget, not on the cap
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(agent);
            agentPay.pay(SESSION, keccak256(abi.encode("order", i)), merchant, CAP);
        }
        assertEq(agentPay.remaining(SESSION), 0);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentPay.BudgetExceeded.selector, BUDGET, BUDGET, 1));
        agentPay.pay(SESSION, ORDER2, merchant, 1);
    }

    function test_pay_rejectsAfterExpiry() public {
        _open();
        vm.warp(expiry);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentPay.SessionExpired.selector, expiry));
        agentPay.pay(SESSION, ORDER, merchant, 1e6);
    }

    function test_pay_rejectsAfterRevoke() public {
        _open();
        vm.prank(payer);
        agentPay.revoke(SESSION);
        vm.prank(agent);
        vm.expectRevert(AgentPay.SessionIsRevoked.selector);
        agentPay.pay(SESSION, ORDER, merchant, 1e6);
    }

    function test_revoke_onlyPayer() public {
        _open();
        vm.prank(agent);
        vm.expectRevert(AgentPay.NotPayer.selector);
        agentPay.revoke(SESSION);
    }

    function test_pay_rejectsReplayedOrder() public {
        _open();
        vm.startPrank(agent);
        agentPay.pay(SESSION, ORDER, merchant, 1e6);
        vm.expectRevert(abi.encodeWithSelector(AgentPay.OrderAlreadyPaid.selector, SESSION, ORDER));
        agentPay.pay(SESSION, ORDER, merchant, 1e6);
        vm.stopPrank();
        assertEq(token.balanceOf(merchant), 1e6, "charged once despite the retry");
    }

    function test_sameOrderIdInAnotherSessionIsIndependent() public {
        _open();
        bytes32 second = keccak256("session-2");
        vm.prank(payer);
        agentPay.openSession(second, agent, BUDGET, CAP, expiry);

        vm.startPrank(agent);
        agentPay.pay(SESSION, ORDER, merchant, 1e6);
        agentPay.pay(second, ORDER, merchant, 1e6);
        vm.stopPrank();
        assertEq(token.balanceOf(merchant), 2e6);
    }

    // ---------------------------------------------------------------- allowlist

    function test_allowlistBlocksUnlistedMerchantOnceUsed() public {
        _open();
        vm.prank(payer);
        agentPay.allowMerchant(SESSION, merchant, true);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentPay.MerchantNotAllowed.selector, otherMerchant));
        agentPay.pay(SESSION, ORDER, otherMerchant, 1e6);

        vm.prank(agent);
        agentPay.pay(SESSION, ORDER, merchant, 1e6);
        assertEq(token.balanceOf(merchant), 1e6);
    }

    function test_allowlistCanBeClearedToReopenTheSession() public {
        _open();
        vm.startPrank(payer);
        agentPay.allowMerchant(SESSION, merchant, true);
        agentPay.allowMerchant(SESSION, merchant, false);
        vm.stopPrank();

        vm.prank(agent);
        agentPay.pay(SESSION, ORDER, otherMerchant, 1e6);
        assertEq(token.balanceOf(otherMerchant), 1e6);
    }

    function test_allowMerchant_onlyPayer() public {
        _open();
        vm.prank(agent);
        vm.expectRevert(AgentPay.NotPayer.selector);
        agentPay.allowMerchant(SESSION, merchant, true);
    }

    // ---------------------------------------------------------------- gasless

    function _sign(uint256 pk, bytes32 orderId, uint256 value)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        Signing.Auth memory a = Signing.Auth({
            from: payer,
            to: address(agentPay),
            value: value,
            validAfter: 0,
            validBefore: block.timestamp + 1 hours,
            nonce: agentPay.paymentNonce(SESSION, orderId)
        });
        return Signing.signReceive(vm, pk, token.DOMAIN_SEPARATOR(), a);
    }

    function _auth(bytes32 orderId, uint256 value)
        internal
        view
        returns (AgentPay.Authorization memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = _sign(payerKey, orderId, value);
        return AgentPay.Authorization({
            validAfter: 0,
            validBefore: block.timestamp + 1 hours,
            v: v,
            r: r,
            s: s
        });
    }

    function test_payWithAuthorization_relayerPaysGasForTheAgent() public {
        _open();
        uint256 value = 7e6;
        vm.prank(relayer);
        agentPay.payWithAuthorization(SESSION, ORDER, merchant, value, _auth(ORDER, value));

        assertEq(token.balanceOf(merchant), value);
        assertEq(token.balanceOf(address(agentPay)), 0);
        assertEq(agentPay.remaining(SESSION), BUDGET - value);
        assertTrue(agentPay.isOrderPaid(SESSION, ORDER));
    }

    function test_payWithAuthorization_respectsBudgetCap() public {
        _open();
        uint256 value = CAP + 1;
        // build the signature BEFORE expectRevert: _auth makes an external call
        // (DOMAIN_SEPARATOR), which would otherwise consume the expectation.
        AgentPay.Authorization memory auth = _auth(ORDER, value);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(AgentPay.PerPaymentCapExceeded.selector, CAP, value));
        agentPay.payWithAuthorization(SESSION, ORDER, merchant, value, auth);
    }

    function test_payWithAuthorization_signatureIsBoundToTheOrder() public {
        _open();
        uint256 value = 3e6;
        // payer signs ORDER2 ...
        AgentPay.Authorization memory leaked = _auth(ORDER2, value);

        // ... a relayer cannot spend it on ORDER
        vm.prank(relayer);
        vm.expectRevert();
        agentPay.payWithAuthorization(SESSION, ORDER, merchant, value, leaked);
        assertEq(token.balanceOf(merchant), 0);
    }

    function test_payWithAuthorization_cannotReplay() public {
        _open();
        uint256 value = 4e6;
        AgentPay.Authorization memory auth = _auth(ORDER, value);

        vm.startPrank(relayer);
        agentPay.payWithAuthorization(SESSION, ORDER, merchant, value, auth);
        vm.expectRevert(abi.encodeWithSelector(AgentPay.OrderAlreadyPaid.selector, SESSION, ORDER));
        agentPay.payWithAuthorization(SESSION, ORDER, merchant, value, auth);
        vm.stopPrank();
        assertEq(token.balanceOf(merchant), value);
    }

    function test_payWithAuthorization_blockedAfterRevoke() public {
        _open();
        AgentPay.Authorization memory auth = _auth(ORDER, 5e6);
        vm.prank(payer);
        agentPay.revoke(SESSION);

        vm.prank(relayer);
        vm.expectRevert(AgentPay.SessionIsRevoked.selector);
        agentPay.payWithAuthorization(SESSION, ORDER, merchant, 5e6, auth);
    }
}