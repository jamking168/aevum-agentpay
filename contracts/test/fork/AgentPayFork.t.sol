// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentPay} from "../../src/AgentPay.sol";
import {Signing} from "../Signing.sol";

interface ITUSD8 is IERC20 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function authorizationState(address, bytes32) external view returns (bool);
}

/// @notice AgentPay against the REAL tUSD8 on a local fork of Aevum testnet.
///         `deal` writes a balance into the fork only, so no funds are needed.
///         Run: make test-fork
contract AgentPayForkTest is Test {
    ITUSD8 constant TUSD8 = ITUSD8(0x456569838f1d43009A91ebA4263147Afd7233483);

    AgentPay agentPay;
    address merchant = makeAddr("merchant");
    address agent = makeAddr("agent");
    address relayer = makeAddr("relayer");

    bytes32 constant SESSION = keccak256("fork-session");
    bytes32 constant ORDER = keccak256("fork-order");
    uint256 constant BUDGET = 50e6;
    uint256 constant CAP = 10e6;

    function test_realTusd8_agentSession() public {
        assertEq(block.chainid, 44005, "run with --fork-url aevum");
        (address payer, uint256 payerKey) = makeAddrAndKey("payer");
        agentPay = new AgentPay(TUSD8);
        deal(address(TUSD8), payer, 100e6);
        uint64 expiry = uint64(block.timestamp + 1 days);

        vm.startPrank(payer);
        TUSD8.approve(address(agentPay), BUDGET);
        agentPay.openSession(SESSION, agent, BUDGET, CAP, expiry);

        // 1) the agent pays directly, within its cap
        vm.stopPrank();
        vm.prank(agent);
        agentPay.pay(SESSION, ORDER, merchant, 4e6);
        assertEq(TUSD8.balanceOf(merchant), 4e6);
        assertEq(agentPay.remaining(SESSION), BUDGET - 4e6);

        // 2) the payer signs one more payment; a relayer submits it, the agent needs no gas
        bytes32 order2 = keccak256("fork-order-2");
        uint256 value = 6e6;
        uint256 deadline = block.timestamp + 1 hours;
        Signing.Auth memory a = Signing.Auth({
            from: payer,
            to: address(agentPay),
            value: value,
            validAfter: 0,
            validBefore: deadline,
            nonce: agentPay.paymentNonce(SESSION, order2)
        });
        (uint8 v, bytes32 r, bytes32 s) = Signing.signReceive(vm, payerKey, TUSD8.DOMAIN_SEPARATOR(), a);

        AgentPay.Authorization memory auth =
            AgentPay.Authorization({validAfter: 0, validBefore: deadline, v: v, r: r, s: s});
        vm.prank(relayer);
        agentPay.payWithAuthorization(SESSION, order2, merchant, value, auth);

        assertEq(TUSD8.balanceOf(merchant), 4e6 + value);
        assertEq(TUSD8.balanceOf(address(agentPay)), 0, "no custody, ever");
        assertTrue(TUSD8.authorizationState(payer, agentPay.paymentNonce(SESSION, order2)));

        // 3) the same signature again is refused on-chain by AgentPay's own order guard
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(AgentPay.OrderAlreadyPaid.selector, SESSION, order2));
        agentPay.payWithAuthorization(SESSION, order2, merchant, value, auth);
    }

    function test_realTusd8_capIsEnforcedOnTheRealToken() public {
        (address payer,) = makeAddrAndKey("payer2");
        agentPay = new AgentPay(TUSD8);
        deal(address(TUSD8), payer, 100e6);
        vm.startPrank(payer);
        TUSD8.approve(address(agentPay), BUDGET);
        agentPay.openSession(SESSION, agent, BUDGET, CAP, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentPay.PerPaymentCapExceeded.selector, CAP, CAP + 1));
        agentPay.pay(SESSION, ORDER, merchant, CAP + 1);
        assertEq(TUSD8.balanceOf(merchant), 0);
    }
}
