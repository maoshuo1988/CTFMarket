// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {PolymarketStyleMarketCreator} from "../src/exchange/PolymarketStyleMarketCreator.sol";

contract ConditionalTokensMock {
    function prepareCondition(address, bytes32, uint256) external {}

    function getConditionId(
        address oracle,
        bytes32 questionId,
        uint256 outcomeSlotCount
    ) external pure returns (bytes32) {
        return
            keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
    }
}

/// @dev Pure unit test: only checks createMarket returns ids.
///      We don't call into UMA/ConditionalTokens here (those are external dependencies).
contract PolymarketStyleMarketCreator_UnitTest is Test {
    PolymarketStyleMarketCreator creator;

    ConditionalTokensMock ct;

    function setUp() external {
        ct = new ConditionalTokensMock();

        // UMA oracle isn't used by createMarket. Collateral token isn't used either.
        creator = new PolymarketStyleMarketCreator(
            address(ct),
            address(12),
            address(13)
        );
    }

    function test_createMarket_returnsNonZeroIds() external {
        (bytes32 conditionId, bytes32 questionId) = creator.createMarket(
            "will it rain tomorrow?"
        );
        assertTrue(conditionId != bytes32(0));
        assertTrue(questionId != bytes32(0));
    }

    function test_ownerCanUpdateUmaOracle() external {
        // sanity
    assertEq(address(creator.umaOracle()), address(12));

        creator.setUmaOracle(address(0x9f1263B8f0355673619168b5B8c0248f1d03e88C));
        assertEq(
            address(creator.umaOracle()),
            address(0x9f1263B8f0355673619168b5B8c0248f1d03e88C)
        );
    }
}
