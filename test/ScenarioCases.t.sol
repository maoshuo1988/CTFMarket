// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {MinimalConditionalTokens} from "../src/exchange/MinimalConditionalTokens.sol";
import {MockERC20} from "../src/exchange/MockERC20.sol";

/// @notice 覆盖 docs/测试用例场景.md 的三个用例（以合约可验证的“净资金流”为准，Gas 成本在 Foundry 中不计入 ERC20 余额）。
contract ScenarioCases_Test is Test {
    MinimalConditionalTokens ct;
    MockERC20 usdc;

    address oracle = address(0xBEEF);
    address A = address(0xA);
    address B = address(0xB);
    address C = address(0xC);

    function setUp() external {
        ct = new MinimalConditionalTokens(oracle);
        usdc = new MockERC20("Mock USDC", "mUSDC");

        usdc.mint(A, 1000e6);
        usdc.mint(B, 1000e6);
        usdc.mint(C, 1000e6);

        vm.prank(A);
        usdc.approve(address(ct), type(uint256).max);
        vm.prank(B);
        usdc.approve(address(ct), type(uint256).max);
        vm.prank(C);
        usdc.approve(address(ct), type(uint256).max);
    }

    function _prepare(
        bytes32 questionId
    ) internal returns (bytes32 conditionId) {
        ct.prepareCondition(oracle, questionId, 2);
        conditionId = ct.getConditionId(oracle, questionId, 2);
    }

    function _resolve(bytes32 questionId, uint256 yes, uint256 no) internal {
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = yes;
        payouts[1] = no;
        vm.prank(oracle);
        ct.reportPayouts(questionId, payouts);
    }

    function _redeemYes(bytes32 conditionId, address user) internal {
        uint256[] memory idx = new uint256[](1);
        idx[0] = 1; // YES indexSet
        vm.prank(user);
        ct.redeemPositions(usdc, bytes32(0), conditionId, idx);
    }

    function _redeemNo(bytes32 conditionId, address user) internal {
        uint256[] memory idx = new uint256[](1);
        idx[0] = 2; // NO indexSet
        vm.prank(user);
        ct.redeemPositions(usdc, bytes32(0), conditionId, idx);
    }

    /// @dev 用例#001：单人 YES，YES 胜 => 资金原路返回（不计 gas）。
    function test_case001_singleUserCorrect() external {
        bytes32 q = keccak256("case001");
        bytes32 conditionId = _prepare(q);

        uint256[] memory part = new uint256[](2);
        part[0] = 1;
        part[1] = 0; // only YES

        uint256 beforeA = usdc.balanceOf(A);
        vm.prank(A);
        ct.splitPosition(usdc, bytes32(0), conditionId, part, 1000e6);

        _resolve(q, 1, 0); // YES wins
        _redeemYes(conditionId, A);

        uint256 afterA = usdc.balanceOf(A);

        // 打印：用户结算后的总额（此用例只有 A）
        console2.log("[case001] A final balance:", afterA);
        console2.log(
            "[case001] A net delta:",
            int256(afterA) - int256(beforeA)
        );
        console2.log(
            "[case001] users total settlement (sum final balances):",
            afterA
        );
        assertEq(afterA, beforeA);
    }

    /// @dev 用例#002：A YES 600，B NO 400，YES 胜 => A 赎回 1000，B 赎回 0。
    function test_case002_twoUsers_oppositeSides() external {
        bytes32 q = keccak256("case002");
        bytes32 conditionId = _prepare(q);

        uint256 beforeA = usdc.balanceOf(A);
        uint256 beforeB = usdc.balanceOf(B);

        uint256[] memory yesOnly = new uint256[](2);
        yesOnly[0] = 1;
        yesOnly[1] = 0;

        uint256[] memory noOnly = new uint256[](2);
        noOnly[0] = 0;
        noOnly[1] = 1;

        vm.prank(A);
        ct.splitPosition(usdc, bytes32(0), conditionId, yesOnly, 600e6);
        vm.prank(B);
        ct.splitPosition(usdc, bytes32(0), conditionId, noOnly, 400e6);

        _resolve(q, 1, 0); // YES wins

        _redeemYes(conditionId, A);
        _redeemNo(conditionId, B);

        uint256 afterA = usdc.balanceOf(A);
        uint256 afterB = usdc.balanceOf(B);
        console2.log("[case002] A final balance:", afterA);
        console2.log("[case002] B final balance:", afterB);
        console2.log(
            "[case002] A net delta:",
            int256(afterA) - int256(beforeA)
        );
        console2.log(
            "[case002] B net delta:",
            int256(afterB) - int256(beforeB)
        );
        console2.log(
            "[case002] users total settlement (sum final balances):",
            afterA + afterB
        );

        assertEq(afterA, beforeA + 400e6);
        assertEq(afterB, beforeB - 400e6);
    }

    /// @dev 用例#003：A YES 200，B NO 300，C YES 250，YES 胜 => A/C 按比例分走总池 750。
    function test_case003_threeUsers() external {
        bytes32 q = keccak256("case003");
        bytes32 conditionId = _prepare(q);

        uint256 beforeA = usdc.balanceOf(A);
        uint256 beforeB = usdc.balanceOf(B);
        uint256 beforeC = usdc.balanceOf(C);

        uint256[] memory yesOnly = new uint256[](2);
        yesOnly[0] = 1;
        yesOnly[1] = 0;

        uint256[] memory noOnly = new uint256[](2);
        noOnly[0] = 0;
        noOnly[1] = 1;

        vm.prank(A);
        ct.splitPosition(usdc, bytes32(0), conditionId, yesOnly, 200e6);
        vm.prank(B);
        ct.splitPosition(usdc, bytes32(0), conditionId, noOnly, 300e6);
        vm.prank(C);
        ct.splitPosition(usdc, bytes32(0), conditionId, yesOnly, 250e6);

        _resolve(q, 1, 0); // YES wins

        _redeemYes(conditionId, A);
        _redeemNo(conditionId, B);
        _redeemYes(conditionId, C);

        uint256 afterA = usdc.balanceOf(A);
        uint256 afterB = usdc.balanceOf(B);
        uint256 afterC = usdc.balanceOf(C);
        console2.log("[case003] A final balance:", afterA);
        console2.log("[case003] B final balance:", afterB);
        console2.log("[case003] C final balance:", afterC);
        console2.log(
            "[case003] A net delta:",
            int256(afterA) - int256(beforeA)
        );
        console2.log(
            "[case003] B net delta:",
            int256(afterB) - int256(beforeB)
        );
        console2.log(
            "[case003] C net delta:",
            int256(afterC) - int256(beforeC)
        );
        console2.log(
            "[case003] users total settlement (sum final balances):",
            afterA + afterB + afterC
        );

        // 总池 = 750，YES 总份额 = 450
        // A 赎回 = 750 * 200 / 450 = 333.333333 -> 向下取整
        // C 赎回 = 750 * 250 / 450 = 416.666666 -> 向下取整
        uint256 pool = 750e6;
        uint256 yesTotal = 450e6;
        uint256 expectedA = (pool * 200e6) / yesTotal;
        uint256 expectedC = (pool * 250e6) / yesTotal;

        assertEq(afterA, beforeA - 200e6 + expectedA);
        assertEq(afterB, beforeB - 300e6);
        assertEq(afterC, beforeC - 250e6 + expectedC);
    }
}
