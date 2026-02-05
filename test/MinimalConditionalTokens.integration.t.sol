// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {MinimalConditionalTokens} from "../src/exchange/MinimalConditionalTokens.sol";
import {MockERC20} from "../src/exchange/MockERC20.sol";

contract MinimalConditionalTokens_IntegrationTest is Test {
    MinimalConditionalTokens ct;
    MockERC20 collateral;

    address umaOracle = address(0xBEEF);
    address alice = address(0xA11CE);

    function setUp() external {
        ct = new MinimalConditionalTokens();
        collateral = new MockERC20("Mock USD", "mUSD");

        collateral.mint(alice, 100 ether);

        vm.prank(alice);
        collateral.approve(address(ct), type(uint256).max);
    }

    function test_fullFlow_split_report_redeem_yesWins() external {
        bytes32 questionId = keccak256("Q1");

        ct.prepareCondition(umaOracle, questionId, 2);

        bytes32 conditionId = ct.getConditionId(umaOracle, questionId, 2);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        vm.prank(alice);
        ct.splitPosition(collateral, bytes32(0), conditionId, partition, 10 ether);

        // UMA oracle reports YES wins: [0, 1e6]
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 0;
        payouts[1] = 1e6;

        vm.prank(umaOracle);
        ct.reportPayouts(questionId, payouts);

        uint256 aliceBefore = collateral.balanceOf(alice);

        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = 2; // NO/YES mapping in this minimal impl: 1->outcome0, 2->outcome1

        vm.prank(alice);
        ct.redeemPositions(collateral, bytes32(0), conditionId, indexSets);

        uint256 aliceAfter = collateral.balanceOf(alice);
        // She deposited 10 ether, and YES wins => redeem returns full 10 ether.
        assertEq(aliceAfter - aliceBefore, 10 ether);
    }

    function test_onlyOracleCanReportPayouts() external {
        bytes32 questionId = keccak256("Q2");
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

    // 未 prepareCondition 的情况下，应该先命中 ConditionNotPrepared。
    vm.expectRevert(MinimalConditionalTokens.ConditionNotPrepared.selector);
    ct.reportPayouts(questionId, payouts);

    // prepareCondition 后，才会进入 oracle 校验。
    ct.prepareCondition(umaOracle, questionId, 2);

    vm.expectRevert(MinimalConditionalTokens.WrongOracle.selector);
    vm.prank(alice);
    ct.reportPayouts(questionId, payouts);
    }
}
