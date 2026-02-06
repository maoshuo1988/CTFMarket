// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {UnifiedMarket} from "../src/exchange/UnifiedMarket.sol";

/// @notice Sepolia 校验脚本：
/// - 从环境变量读取 UNIFIED_MARKET
/// - 读取 market 的 conditionalTokens/collateralToken/oracle 并打印
contract SepoliaVerifyUnifiedMarket is Script {
    function run() external view {
        address marketAddr = vm.envAddress("UNIFIED_MARKET");
        UnifiedMarket market = UnifiedMarket(marketAddr);

        console2.log("chainid", block.chainid);
        console2.log("UnifiedMarket", marketAddr);
        console2.log("conditionalTokens", address(market.conditionalTokens()));
        console2.log("collateralToken", address(market.collateralToken()));
        console2.log("oracle", market.oracle());
        console2.log("owner", market.owner());
    }
}
