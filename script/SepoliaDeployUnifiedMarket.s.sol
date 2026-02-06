// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {UnifiedMarket} from "../src/exchange/UnifiedMarket.sol";
import {MinimalConditionalTokens} from "../src/exchange/MinimalConditionalTokens.sol";
import {MockERC20} from "../src/exchange/MockERC20.sol";

/// @dev 辅助合约：把库函数调用变成外部调用，从而可用 try/catch 探测 JSON 数组越界。
contract ExternalJsonReader {
    using stdJson for string;

    function readString(string memory json, string memory path) external pure returns (string memory) {
        return json.readString(path);
    }

    function readAddress(string memory json, string memory path) external pure returns (address) {
        return json.readAddress(path);
    }
}

/// @notice Sepolia 部署脚本（方案B，自部署依赖）：
/// - oracle 使用 network/11155111.json 里的 UMA OptimisticOracleV2
/// - 在 Sepolia 上依次部署：MockERC20(collateral) -> MinimalConditionalTokens -> UnifiedMarket
/// - 无需在 .env 提供 CONDITIONAL_TOKENS/COLLATERAL_TOKEN
contract SepoliaDeployUnifiedMarket is Script {
    using stdJson for string;

    ExternalJsonReader private reader;

    function _readOracleFromNetworkJson() internal view returns (address oracle) {
        // network/11155111.json 是一个对象数组：[{contractName,address}, ...]
        string memory path = string.concat(vm.projectRoot(), "/network/11155111.json");
        string memory json = vm.readFile(path);

        // 线性扫描数组，越界时 readString 会 revert；通过外部调用 reader 来 try/catch。
        for (uint256 i = 0; i < 256; i++) {
            string memory name;
            try reader.readString(
                json,
                string.concat("$[", vm.toString(i), "].contractName")
            ) returns (string memory v) {
                name = v;
            } catch {
                break;
            }

            if (keccak256(bytes(name)) == keccak256(bytes("OptimisticOracleV2"))) {
                return
                    reader.readAddress(
                        json,
                        string.concat("$[", vm.toString(i), "].address")
                    );
            }
        }

        revert("OptimisticOracleV2 not found in network/11155111.json");
    }

    function run() external {
        if (address(reader) == address(0)) {
            reader = new ExternalJsonReader();
        }
    // IMPORTANT: 如果你的 .env PRIVATE_KEY 是 hex 字符串，必须带 0x 前缀，否则 envUint 会解析失败。
    uint256 pk = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(pk);
    address oracle = _readOracleFromNetworkJson();
    require(oracle != address(0), "oracle=0");

        console2.log("chainid", block.chainid);
        console2.log("deployer", deployer);
        console2.log("oracle", oracle);

        vm.startBroadcast(pk);
        MockERC20 collateralToken = new MockERC20("Mock USDC", "mUSDC");
        MinimalConditionalTokens conditionalTokens = new MinimalConditionalTokens(oracle);
        UnifiedMarket market = new UnifiedMarket(
            address(conditionalTokens),
            address(collateralToken),
            oracle
        );
        vm.stopBroadcast();

        console2.log("deployed MockERC20(collateral)", address(collateralToken));
        console2.log(
            "deployed MinimalConditionalTokens",
            address(conditionalTokens)
        );
        console2.log("deployed UnifiedMarket", address(market));

        // minimal sanity checks
        require(
            address(market.conditionalTokens()) == address(conditionalTokens),
            "market.ct mismatch"
        );
        require(
            address(market.collateralToken()) == address(collateralToken),
            "market.collateral mismatch"
        );
        require(market.oracle() == oracle, "market.oracle mismatch");
    }
}
