// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {UnifiedMarket} from "../src/exchange/UnifiedMarket.sol";

/// @notice 轻量 Sepolia 冒烟脚本：仅部署并打印关键地址/chainId。
/// @dev 不会触发 UMA/ConditionalTokens 的链上交互，避免依赖额度/代币。
contract SepoliaSmoke is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        // Sepolia 上 ConditionalTokens/Collateral/Oracle 需要你提供；这里用环境变量。
        // 注意：UnifiedMarket 构造函数要求这三个地址都非 0，否则会 revert。
    address conditionalTokens = vm.envOr("CONDITIONAL_TOKENS", address(0));
    address collateralToken = vm.envOr("COLLATERAL_TOKEN", address(0));
    address oracle = vm.envOr("ORACLE", address(0));

        require(
            conditionalTokens != address(0) &&
                collateralToken != address(0) &&
                oracle != address(0),
            "env missing: set CONDITIONAL_TOKENS/COLLATERAL_TOKEN/ORACLE"
        );

        console2.log("chainid", block.chainid);
        console2.log("conditionalTokens", conditionalTokens);
        console2.log("collateralToken", collateralToken);
    console2.log("oracle", oracle);

        vm.startBroadcast(pk);

    UnifiedMarket market = new UnifiedMarket(conditionalTokens, collateralToken, oracle);

        vm.stopBroadcast();

    console2.log("deployed UnifiedMarket", address(market));
    }
}
