// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {PolymarketStyleMarketCreator} from "../src/exchange/PolymarketStyleMarketCreator.sol";

/// @notice 轻量 Sepolia 冒烟脚本：仅部署并打印关键地址/chainId。
/// @dev 不会触发 UMA/ConditionalTokens 的链上交互，避免依赖额度/代币。
contract SepoliaSmoke is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        // 来自 D:\Web3Project\protocol\packages\core\networks\11155111.json
        address umaOov2 = 0x9f1263B8f0355673619168b5B8c0248f1d03e88C;

        // Sepolia 上 ConditionalTokens/Collateral 需要你提供；这里用环境变量，没设置就只做“读取/打印”。
        address conditionalTokens = vm.envOr("CONDITIONAL_TOKENS", address(0));
        address collateralToken = vm.envOr("COLLATERAL_TOKEN", address(0));

        console2.log("chainid", block.chainid);
    console2.log("UMA_OOV2", umaOov2);
        console2.log("conditionalTokens", conditionalTokens);
        console2.log("collateralToken", collateralToken);

        vm.startBroadcast(pk);

        // 即便传 0 地址也能部署（只要构造函数不主动外部调用）；后续 createMarket 会依赖真实地址。
        PolymarketStyleMarketCreator creator = new PolymarketStyleMarketCreator(
            conditionalTokens,
            umaOov2,
            collateralToken
        );

        vm.stopBroadcast();

        console2.log("deployed creator", address(creator));
    }
}
