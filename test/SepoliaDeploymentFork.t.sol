// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {UnifiedMarket} from "../src/exchange/UnifiedMarket.sol";
import {MinimalConditionalTokens} from "../src/exchange/MinimalConditionalTokens.sol";
import {MockERC20} from "../src/exchange/MockERC20.sol";

/// @notice Sepolia 部署验收测试（fork 测试）
///
/// 目标：在本地通过 fork sepolia，验证 UNIFIED_MARKET 指向的合约确实已部署且配置正确。
///
/// 运行方式（示例）：
///   RPC_URL=... UNIFIED_MARKET=0x... forge test --match-contract SepoliaDeploymentForkTest --fork-url $RPC_URL -vvv
contract SepoliaDeploymentForkTest is Test {
    // UMA OptimisticOracleV2 on Sepolia (from network/11155111.json)
    address constant UMA_OO_V2_SEPOLIA = 0x9f1263B8f0355673619168b5B8c0248f1d03e88C;

    /// ====== docs/测试用例场景.md 对应的 Sepolia fork 复现 ======
    /// 注意：
    /// - 文档里的“gas 成本(USDC)”是业务侧估算，这里不把 gas 计入 ERC20 余额。
    /// - 我们验证的是合约层面的“净资金流/赎回逻辑”，与本仓库 `ScenarioCases.t.sol` 保持一致。

    function _newQuestion(bytes32 salt) internal view returns (bytes32) {
        // 避免与链上其他调用冲突：把 market 地址也混进来
        address marketAddr = vm.envAddress("UNIFIED_MARKET");
        return keccak256(abi.encodePacked("sepolia-fork", salt, marketAddr));
    }

    function _prepare(MinimalConditionalTokens ct, address oracle, bytes32 q) internal returns (bytes32 conditionId) {
        ct.prepareCondition(oracle, q, 2);
        conditionId = ct.getConditionId(oracle, q, 2);
    }

    function _resolve(MinimalConditionalTokens ct, bytes32 q, uint256 yes, uint256 no) internal {
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = yes;
        payouts[1] = no;
        // MinimalConditionalTokens 要求 msg.sender == oracle
        // 在 Sepolia 的部署中，oracle = UMA OptimisticOracleV2（合约地址），我们用 prank 模拟其调用。
        vm.prank(UMA_OO_V2_SEPOLIA);
        ct.reportPayouts(q, payouts);
    }

    function _redeemYes(MinimalConditionalTokens ct, MockERC20 usdc, bytes32 conditionId, address user) internal {
        vm.prank(user);
        ct.redeemPositions2(
            usdc,
            bytes32(0),
            conditionId,
            MinimalConditionalTokens.RedeemMask.wrap(1)
        );
    }

    function _redeemNo(MinimalConditionalTokens ct, MockERC20 usdc, bytes32 conditionId, address user) internal {
        vm.prank(user);
        ct.redeemPositions2(
            usdc,
            bytes32(0),
            conditionId,
            MinimalConditionalTokens.RedeemMask.wrap(2)
        );
    }

    function test_sepolia_unifiedMarket_isDeployedAndWired() external view {
        address marketAddr = vm.envAddress("UNIFIED_MARKET");

        // 1) code size check: address must have code on fork
        uint256 size;
        assembly {
            size := extcodesize(marketAddr)
        }
        assertGt(size, 0, "UNIFIED_MARKET has no code");

        // 2) read config from onchain contract
        UnifiedMarket market = UnifiedMarket(marketAddr);

        assertEq(market.oracle(), UMA_OO_V2_SEPOLIA, "oracle mismatch");
        assertTrue(address(market.conditionalTokens()) != address(0), "ct=0");
        assertTrue(address(market.collateralToken()) != address(0), "collateral=0");

        // 3) referenced contracts should also have code
        uint256 ctSize;
        uint256 colSize;
        address ct = address(market.conditionalTokens());
        address col = address(market.collateralToken());
        assembly {
            ctSize := extcodesize(ct)
            colSize := extcodesize(col)
        }
        assertGt(ctSize, 0, "conditionalTokens has no code");
        assertGt(colSize, 0, "collateralToken has no code");
    }

    /// @dev 用例#001：单人 YES 且 YES 胜，资金原路返回（忽略 gas）
    function test_sepolia_case001_singleUserCorrect() external {
        UnifiedMarket market = UnifiedMarket(vm.envAddress("UNIFIED_MARKET"));
        MinimalConditionalTokens ct = MinimalConditionalTokens(address(market.conditionalTokens()));
        MockERC20 usdc = MockERC20(address(market.collateralToken()));

        address A = address(0xA11CE);

        // fork 场景下我们直接铸币给用户（MockERC20 支持 mint）
        usdc.mint(A, 1000e6);
        vm.prank(A);
        usdc.approve(address(ct), type(uint256).max);

        bytes32 q = _newQuestion(keccak256("case001"));
        bytes32 conditionId = _prepare(ct, market.oracle(), q);

        uint256 beforeA = usdc.balanceOf(A);
        vm.prank(A);
        ct.splitPosition2(
            usdc,
            bytes32(0),
            conditionId,
            MinimalConditionalTokens.SplitKind.YES_ONLY,
            1000e6
        );

        _resolve(ct, q, 1, 0);
        _redeemYes(ct, usdc, conditionId, A);

        uint256 afterA = usdc.balanceOf(A);
        assertEq(afterA, beforeA, "case001: A balance should be unchanged");
    }

    /// @dev 用例#002：A YES 600，B NO 400，YES 胜
    /// - A 赎回 1000
    /// - B 赎回 0
    function test_sepolia_case002_twoUsers_oppositeSides() external {
        UnifiedMarket market = UnifiedMarket(vm.envAddress("UNIFIED_MARKET"));
        MinimalConditionalTokens ct = MinimalConditionalTokens(address(market.conditionalTokens()));
        MockERC20 usdc = MockERC20(address(market.collateralToken()));

        address A = address(0xA);
        address B = address(0xB);

        usdc.mint(A, 1000e6);
        usdc.mint(B, 1000e6);
        vm.prank(A);
        usdc.approve(address(ct), type(uint256).max);
        vm.prank(B);
        usdc.approve(address(ct), type(uint256).max);

        bytes32 q = _newQuestion(keccak256("case002"));
        bytes32 conditionId = _prepare(ct, market.oracle(), q);

        uint256 beforeA = usdc.balanceOf(A);
        uint256 beforeB = usdc.balanceOf(B);

        vm.prank(A);
        ct.splitPosition2(
            usdc,
            bytes32(0),
            conditionId,
            MinimalConditionalTokens.SplitKind.YES_ONLY,
            600e6
        );
        vm.prank(B);
        ct.splitPosition2(
            usdc,
            bytes32(0),
            conditionId,
            MinimalConditionalTokens.SplitKind.NO_ONLY,
            400e6
        );

        _resolve(ct, q, 1, 0);
        _redeemYes(ct, usdc, conditionId, A);
        _redeemNo(ct, usdc, conditionId, B);

        uint256 afterA = usdc.balanceOf(A);
        uint256 afterB = usdc.balanceOf(B);

        assertEq(afterA, beforeA + 400e6, "case002: A should win B's stake");
        assertEq(afterB, beforeB - 400e6, "case002: B should lose stake");
    }

    /// @dev 用例#003：A YES 200，B NO 300，C YES 250，YES 胜
    function test_sepolia_case003_threeUsers() external {
        UnifiedMarket market = UnifiedMarket(vm.envAddress("UNIFIED_MARKET"));
        MinimalConditionalTokens ct = MinimalConditionalTokens(address(market.conditionalTokens()));
        MockERC20 usdc = MockERC20(address(market.collateralToken()));

        address A = address(0xA);
        address B = address(0xB);
        address C = address(0xC);

        usdc.mint(A, 1000e6);
        usdc.mint(B, 1000e6);
        usdc.mint(C, 1000e6);
        vm.prank(A);
        usdc.approve(address(ct), type(uint256).max);
        vm.prank(B);
        usdc.approve(address(ct), type(uint256).max);
        vm.prank(C);
        usdc.approve(address(ct), type(uint256).max);

        bytes32 q = _newQuestion(keccak256("case003"));
        bytes32 conditionId = _prepare(ct, market.oracle(), q);

        uint256 beforeA = usdc.balanceOf(A);
        uint256 beforeB = usdc.balanceOf(B);
        uint256 beforeC = usdc.balanceOf(C);

        vm.prank(A);
        ct.splitPosition2(
            usdc,
            bytes32(0),
            conditionId,
            MinimalConditionalTokens.SplitKind.YES_ONLY,
            200e6
        );
        vm.prank(B);
        ct.splitPosition2(
            usdc,
            bytes32(0),
            conditionId,
            MinimalConditionalTokens.SplitKind.NO_ONLY,
            300e6
        );
        vm.prank(C);
        ct.splitPosition2(
            usdc,
            bytes32(0),
            conditionId,
            MinimalConditionalTokens.SplitKind.YES_ONLY,
            250e6
        );

        _resolve(ct, q, 1, 0);
        _redeemYes(ct, usdc, conditionId, A);
        _redeemNo(ct, usdc, conditionId, B);
        _redeemYes(ct, usdc, conditionId, C);

        uint256 afterA = usdc.balanceOf(A);
        uint256 afterB = usdc.balanceOf(B);
        uint256 afterC = usdc.balanceOf(C);

        uint256 pool = 750e6;
        uint256 yesTotal = 450e6;
        uint256 expectedA = (pool * 200e6) / yesTotal;
        uint256 expectedC = (pool * 250e6) / yesTotal;

        assertEq(afterA, beforeA - 200e6 + expectedA, "case003: A redeem mismatch");
        assertEq(afterB, beforeB - 300e6, "case003: B should lose stake");
        assertEq(afterC, beforeC - 250e6 + expectedC, "case003: C redeem mismatch");
    }
}
