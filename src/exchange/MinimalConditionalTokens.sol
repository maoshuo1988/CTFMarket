// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice 最小版 ConditionalTokens：
/// - 支持 prepareCondition / reportPayouts / (内部) resolveCondition
/// - 支持 splitPosition(仅 collateral -> YES/NO 两仓) 与 redeemPositions
///
/// @dev 这是“按 doc/design.md 跑通链路”的最小实现，不是完整 Gnosis ConditionalTokens/ ERC1155。
///      关键目标：
///      1) CT 合约自身持有入金（collateral）
///      2) 由 oracle(这里是 umaOracle 地址) 调用 reportPayouts
///      3) resolve 后用户可 redeemPositions 拿回 collateral
contract MinimalConditionalTokens is Ownable(msg.sender) {
    error ConditionNotPrepared();
    error WrongOracle();
    error AlreadyResolved();
    error InvalidOutcomeSlotCount();
    error PayoutAllZero();
    error InvalidIndexSet();

    event ConditionPrepared(
        bytes32 indexed conditionId, address indexed oracle, bytes32 indexed questionId, uint256 outcomeSlotCount
    );

    event ConditionResolved(
        bytes32 indexed conditionId,
        address indexed oracle,
        bytes32 indexed questionId,
        uint256 outcomeSlotCount,
        uint256[] payoutNumerators,
        uint256 payoutDenominator
    );

    event PositionSplit(
        address indexed stakeholder, IERC20 indexed collateralToken, bytes32 indexed conditionId, uint256 amount
    );

    event PayoutRedemption(
        address indexed redeemer, IERC20 indexed collateralToken, bytes32 indexed conditionId, uint256 payout
    );

    struct Condition {
        address oracle;
        bytes32 questionId;
        uint256 outcomeSlotCount;
        uint256 payoutDenominator; // 0 == unresolved
        uint256[2] payoutNumerators; // only 2 outcomes (YES/NO)
    }

    // conditionId => condition
    mapping(bytes32 => Condition) public conditions;

    // questionId => oracle (仅用于本最小实现，便于从 questionId 找回 condition)
    mapping(bytes32 => address) public oracleByQuestionId;

    // (user, conditionId, outcomeIndex) => stake
    mapping(address => mapping(bytes32 => mapping(uint256 => uint256))) public balances;

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
    }

    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external {
        if (outcomeSlotCount != 2) revert InvalidOutcomeSlotCount();

        bytes32 conditionId = getConditionId(oracle, questionId, outcomeSlotCount);
        Condition storage c = conditions[conditionId];
        // not prepared iff oracle is zero
        if (c.oracle != address(0)) revert();

        c.oracle = oracle;
        c.questionId = questionId;
        c.outcomeSlotCount = outcomeSlotCount;

    oracleByQuestionId[questionId] = oracle;

        emit ConditionPrepared(conditionId, oracle, questionId, outcomeSlotCount);
    }

    /// @notice 由 oracle(这里期望是 umaOracle 地址) 上报 payouts。
    /// @dev 为了对齐你的“由 CT 合约处理 reportPayouts 并 resolveCondition”，这里 reportPayouts 内部直接调用 _resolveCondition。
    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external {
        if (payouts.length != 2) revert InvalidOutcomeSlotCount();

    address oracle = oracleByQuestionId[questionId];
    if (oracle == address(0)) revert ConditionNotPrepared();

    bytes32 conditionId = getConditionId(oracle, questionId, payouts.length);
    Condition storage c = conditions[conditionId];
    if (c.oracle == address(0)) revert ConditionNotPrepared();
    if (c.oracle != msg.sender) revert WrongOracle();
    if (c.payoutDenominator != 0) revert AlreadyResolved();

        uint256 den = payouts[0] + payouts[1];
        if (den == 0) revert PayoutAllZero();

        c.payoutNumerators[0] = payouts[0];
        c.payoutNumerators[1] = payouts[1];
        c.payoutDenominator = den;

        emit ConditionResolved(conditionId, msg.sender, questionId, 2, payouts, den);
    }

    /// @notice 仅支持从 collateral 拆分成 YES(1) / NO(2) 两个 indexSet。
    /// @dev partition 形如 [1,2]；amount 会分别计入两个 outcome 仓。
    function splitPosition(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external {
        // 这个最小实现不支持多层 collection。
        if (parentCollectionId != bytes32(0)) revert();

        Condition storage c = conditions[conditionId];
        if (c.oracle == address(0)) revert ConditionNotPrepared();
        if (c.outcomeSlotCount != 2) revert InvalidOutcomeSlotCount();
        if (partition.length != 2) revert();
        if (!(partition[0] == 1 && partition[1] == 2) && !(partition[0] == 2 && partition[1] == 1)) revert();

        require(collateralToken.transferFrom(msg.sender, address(this), amount), "collateral transfer failed");

        // 简化：amount 等分“头寸份额”。真实 CT 是按 ERC1155 头寸 token。
        balances[msg.sender][conditionId][0] += amount;
        balances[msg.sender][conditionId][1] += amount;

        emit PositionSplit(msg.sender, collateralToken, conditionId, amount);
    }

    /// @notice 在 condition resolved 后赎回。
    /// @dev indexSets 支持 [1] or [2] or [1,2]。
    function redeemPositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external {
        if (parentCollectionId != bytes32(0)) revert();

        Condition storage c = conditions[conditionId];
        if (c.oracle == address(0)) revert ConditionNotPrepared();
        uint256 den = c.payoutDenominator;
        if (den == 0) revert();

        uint256 totalPayout = 0;
        for (uint256 i = 0; i < indexSets.length; i++) {
            uint256 idx = indexSets[i];
            if (idx != 1 && idx != 2) revert InvalidIndexSet();

            uint256 outcomeIndex = idx == 1 ? 0 : 1;
            uint256 stake = balances[msg.sender][conditionId][outcomeIndex];
            if (stake == 0) continue;

            balances[msg.sender][conditionId][outcomeIndex] = 0;

            // payout = stake * numerator / denominator
            totalPayout += (stake * c.payoutNumerators[outcomeIndex]) / den;
        }

        if (totalPayout > 0) {
            require(collateralToken.transfer(msg.sender, totalPayout), "payout transfer failed");
        }

        emit PayoutRedemption(msg.sender, collateralToken, conditionId, totalPayout);
    }
}
