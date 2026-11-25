// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentPay} from "../src/AgentPay.sol";
import {MockUSD8} from "../src/mocks/MockUSD8.sol";

/// @notice Deploys AgentPay.
///   - Aevum testnet and `make fork`: uses the real tUSD8 at 0x4565…3483.
///   - `make anvil` (chain 31337) only: deploys MockUSD8 instead and mints 1,000 to the deployer.
///   - Anywhere else it stops rather than deploy a token anyone can mint.
///
///   make deploy-agentpay-aevum ACCOUNT=aevum-deployer
///   make deploy-agentpay-fork
contract DeployAgentPay is Script {
    address constant AEVUM_TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;
    uint256 constant ANVIL_CHAIN = 31337;

    function run() external returns (AgentPay agentPay, address token) {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        if (AEVUM_TUSD8.code.length > 0) {
            token = AEVUM_TUSD8;
        } else {
            require(
                block.chainid == ANVIL_CHAIN,
                "tUSD8 not found on this chain. Check the RPC (Aevum testnet is 44005)."
            );
            MockUSD8 mock = new MockUSD8();
            mock.mint(deployer, 1_000e6);
            token = address(mock);
        }

        agentPay = new AgentPay(IERC20(token));
        vm.stopBroadcast();

        console.log("chainId  ", block.chainid);
        console.log("token    ", token);
        console.log("AgentPay ", address(agentPay));
        console.log("deployer ", deployer);
    }
}
