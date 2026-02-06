// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice ERC1155 版 MinimalConditionalTokens：
/// - 覆盖本仓库业务需要的最小子集（prepareCondition / reportPayouts / splitPosition / redeemPositions）
/// - 头寸为可转让的 ERC1155 token（positionId 为 tokenId）
/// - 仅支持二元市场（outcomeSlotCount == 2）与 parentCollectionId == bytes32(0)
///
/// @dev 这不是完整 Gnosis ConditionalTokens。
contract MinimalConditionalTokens is ERC1155, Ownable {
    error ConditionNotPrepared();
    error WrongOracle();
    error AlreadyResolved();
    error InvalidOutcomeSlotCount();
    error PayoutAllZero();
    error InvalidIndexSet();
    error InvalidPartition();
    error InvalidParentCollection();
    error ZeroAmount();

    event ConditionPrepared(
        bytes32 indexed conditionId,
        address indexed oracle,
        bytes32 indexed questionId,
        uint256 outcomeSlotCount
    );

    event ConditionResolved(
        bytes32 indexed conditionId,
        address indexed oracle,
        bytes32 indexed questionId,
        uint256 outcomeSlotCount,
        uint256 payoutYes,
        uint256 payoutNo,
        uint256 payoutDenominator
    );

    event PositionSplit(
        address indexed stakeholder,
        IERC20 indexed collateralToken,
        bytes32 indexed conditionId,
        uint256 amount
    );

    event PayoutRedemption(
        address indexed redeemer,
        IERC20 indexed collateralToken,
        bytes32 indexed conditionId,
        uint256 payout
    );

    /// @notice 轻量接口：用于替代 splitPosition 的 partition 数组，节省 calldata/memory。
    /// @dev 0=FULL(YES+NO), 1=YES_ONLY, 2=NO_ONLY
    enum SplitKind {
        FULL,
        YES_ONLY,
        NO_ONLY
    }

    /// @notice 轻量接口：用于替代 redeemPositions 的 indexSets 数组，节省 calldata/memory。
    /// @dev bit0=YES, bit1=NO；例如 1=YES, 2=NO, 3=YES+NO
    type RedeemMask is uint8;

    struct Condition {
        bytes32 questionId;
        uint256 outcomeSlotCount;
        uint256 payoutDenominator; // 0 == unresolved
        uint256[2] payoutNumerators; // only 2 outcomes
        /// @dev 本仓库套利用例模型需要的额外账本：
        /// - collateralPool: 此 condition 下累计进入合约的抵押品总额
        /// - totalShares[i]: outcome i 的累计铸造份额（YES=0, NO=1）
        uint256 collateralPool;
        uint256[2] totalShares;
    }

    mapping(bytes32 => Condition) public conditions;

    /// @notice 简化：所有 condition 共享同一个 oracle。
    address public immutable oracle;

    constructor(address oracle_) ERC1155("") Ownable(msg.sender) {
        require(oracle_ != address(0), "oracle=0");
        oracle = oracle_;
    }

    function _calcPayout(
        Condition storage c,
        uint256 stake,
        uint256 outcomeIndex
    ) internal view returns (uint256) {
        uint256 den = c.payoutDenominator;
        uint256 sideTotal = c.totalShares[outcomeIndex];
        require(sideTotal != 0, "empty side");
        uint256 numerator = c.payoutNumerators[outcomeIndex];
        return (stake * c.collateralPool * numerator) / (den * sideTotal);
    }

    function getConditionId(
        address oracle_,
        bytes32 questionId,
        uint256 outcomeSlotCount
    ) public pure returns (bytes32) {
        return
            keccak256(abi.encodePacked(oracle_, questionId, outcomeSlotCount));
    }

    function getCollectionId(
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256 indexSet
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(parentCollectionId, conditionId, indexSet)
            );
    }

    function getPositionId(
        IERC20 collateralToken,
        bytes32 collectionId
    ) public pure returns (uint256) {
        return
            uint256(keccak256(abi.encodePacked(collateralToken, collectionId)));
    }

    function prepareCondition(
        address oracle_,
        bytes32 questionId,
        uint256 outcomeSlotCount
    ) external {
        if (outcomeSlotCount != 2) revert InvalidOutcomeSlotCount();
        if (oracle_ != oracle) revert WrongOracle();

        bytes32 conditionId = getConditionId(
            oracle,
            questionId,
            outcomeSlotCount
        );
        Condition storage c = conditions[conditionId];
        require(c.outcomeSlotCount == 0, "prepared");

        c.questionId = questionId;
        c.outcomeSlotCount = outcomeSlotCount;

        emit ConditionPrepared(
            conditionId,
            oracle,
            questionId,
            outcomeSlotCount
        );
    }

    function reportPayouts(
        bytes32 questionId,
        uint256[] calldata payouts
    ) external {
        if (payouts.length != 2) revert InvalidOutcomeSlotCount();
        if (msg.sender != oracle) revert WrongOracle();

        bytes32 conditionId = getConditionId(
            oracle,
            questionId,
            payouts.length
        );
        Condition storage c = conditions[conditionId];
        if (c.outcomeSlotCount == 0) revert ConditionNotPrepared();
        if (c.payoutDenominator != 0) revert AlreadyResolved();

        uint256 den = payouts[0] + payouts[1];
        if (den == 0) revert PayoutAllZero();

        c.payoutNumerators[0] = payouts[0];
        c.payoutNumerators[1] = payouts[1];
        c.payoutDenominator = den;

        emit ConditionResolved(
            conditionId,
            msg.sender,
            questionId,
            2,
            payouts[0],
            payouts[1],
            den
        );
    }

    /// @notice 拆分抵押品为 YES/NO 头寸。
    /// @dev 支持 partition:
    /// - [1,2] (或 [2,1])：铸造 amount YES + amount NO
    /// - [1,0]：仅铸造 amount YES
    /// - [0,1]：仅铸造 amount NO
    /// - [1,1]：铸造 amount YES + amount NO（README 的“完整头寸”写法）
    function splitPosition(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external {
        if (amount == 0) revert ZeroAmount();
        if (parentCollectionId != bytes32(0)) revert InvalidParentCollection();
        Condition storage c = conditions[conditionId];
        if (c.outcomeSlotCount == 0) revert ConditionNotPrepared();
        if (c.outcomeSlotCount != 2) revert InvalidOutcomeSlotCount();
        if (partition.length != 2) revert InvalidPartition();

        bool mintYes = false;
        bool mintNo = false;

        // 兼容两种“全头寸”写法：[1,2] 或 [1,1]
        bool isFull = (partition[0] == 1 && partition[1] == 2) ||
            (partition[0] == 2 && partition[1] == 1) ||
            (partition[0] == 1 && partition[1] == 1);

        if (isFull) {
            mintYes = true;
            mintNo = true;
        } else if (partition[0] == 1 && partition[1] == 0) {
            mintYes = true;
        } else if (partition[0] == 0 && partition[1] == 1) {
            mintNo = true;
        } else {
            revert InvalidPartition();
        }

        require(
            collateralToken.transferFrom(msg.sender, address(this), amount),
            "collateral transfer failed"
        );

        // 记录抵押池规模
        c.collateralPool += amount;

        if (mintYes) {
            uint256 yesId = getPositionId(
                collateralToken,
                getCollectionId(parentCollectionId, conditionId, 1)
            );
            _mint(msg.sender, yesId, amount, "");
            c.totalShares[0] += amount;
        }
        if (mintNo) {
            uint256 noId = getPositionId(
                collateralToken,
                getCollectionId(parentCollectionId, conditionId, 2)
            );
            _mint(msg.sender, noId, amount, "");
            c.totalShares[1] += amount;
        }

        emit PositionSplit(msg.sender, collateralToken, conditionId, amount);
    }

    /// @notice splitPosition 的轻量版：用枚举替代 uint256[] partition。
    function splitPosition2(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        SplitKind kind,
        uint256 amount
    ) external {
        if (amount == 0) revert ZeroAmount();
        if (parentCollectionId != bytes32(0)) revert InvalidParentCollection();
        Condition storage c = conditions[conditionId];
        if (c.outcomeSlotCount == 0) revert ConditionNotPrepared();
        if (c.outcomeSlotCount != 2) revert InvalidOutcomeSlotCount();

        bool mintYes;
        bool mintNo;
        if (kind == SplitKind.FULL) {
            mintYes = true;
            mintNo = true;
        } else if (kind == SplitKind.YES_ONLY) {
            mintYes = true;
        } else if (kind == SplitKind.NO_ONLY) {
            mintNo = true;
        } else {
            revert InvalidPartition();
        }

        require(
            collateralToken.transferFrom(msg.sender, address(this), amount),
            "collateral transfer failed"
        );
        c.collateralPool += amount;

        if (mintYes) {
            uint256 yesId = getPositionId(
                collateralToken,
                getCollectionId(parentCollectionId, conditionId, 1)
            );
            _mint(msg.sender, yesId, amount, "");
            c.totalShares[0] += amount;
        }
        if (mintNo) {
            uint256 noId = getPositionId(
                collateralToken,
                getCollectionId(parentCollectionId, conditionId, 2)
            );
            _mint(msg.sender, noId, amount, "");
            c.totalShares[1] += amount;
        }

        emit PositionSplit(msg.sender, collateralToken, conditionId, amount);
    }

    /// @notice condition resolved 后赎回。
    /// @dev indexSets 支持 [1] (YES) / [2] (NO) / [1,2]
    function redeemPositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external {
        if (indexSets.length == 0) return;
        if (parentCollectionId != bytes32(0)) revert InvalidParentCollection();

        Condition storage c = conditions[conditionId];
        if (c.outcomeSlotCount == 0) revert ConditionNotPrepared();

        uint256 den = c.payoutDenominator;
        require(den != 0, "unresolved");

        uint256 totalPayout = 0;

        for (uint256 i = 0; i < indexSets.length; ) {
            uint256 idx = indexSets[i];
            if (idx != 1 && idx != 2) revert InvalidIndexSet();

            uint256 outcomeIndex = idx == 1 ? 0 : 1;
            uint256 positionId = getPositionId(
                collateralToken,
                getCollectionId(parentCollectionId, conditionId, idx)
            );
            uint256 stake = balanceOf(msg.sender, positionId);
            if (stake == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }

            _burn(msg.sender, positionId, stake);

            // 按 docs/测试用例场景.md 的资金流模型：
            // 总池 = collateralPool；胜者侧按 stake/totalShares[outcome] 比例分走总池（再乘以 payoutNumerator/den）。
            totalPayout += _calcPayout(c, stake, outcomeIndex);

            unchecked {
                ++i;
            }
        }

        if (totalPayout > 0) {
            require(
                collateralToken.transfer(msg.sender, totalPayout),
                "payout transfer failed"
            );
        }

        emit PayoutRedemption(
            msg.sender,
            collateralToken,
            conditionId,
            totalPayout
        );
    }

    /// @notice redeemPositions 的轻量版：用位掩码替代 uint256[] indexSets。
    function redeemPositions2(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        RedeemMask mask
    ) external {
        if (parentCollectionId != bytes32(0)) revert InvalidParentCollection();

        Condition storage c = conditions[conditionId];
        if (c.outcomeSlotCount == 0) revert ConditionNotPrepared();
        uint256 den = c.payoutDenominator;
        require(den != 0, "unresolved");

        uint8 m = RedeemMask.unwrap(mask);
        uint256 totalPayout = 0;

        // YES
        if (m & 0x01 != 0) {
            uint256 yesId = getPositionId(
                collateralToken,
                getCollectionId(parentCollectionId, conditionId, 1)
            );
            uint256 stakeYes = balanceOf(msg.sender, yesId);
            if (stakeYes != 0) {
                _burn(msg.sender, yesId, stakeYes);
                totalPayout += _calcPayout(c, stakeYes, 0);
            }
        }
        // NO
        if (m & 0x02 != 0) {
            uint256 noId = getPositionId(
                collateralToken,
                getCollectionId(parentCollectionId, conditionId, 2)
            );
            uint256 stakeNo = balanceOf(msg.sender, noId);
            if (stakeNo != 0) {
                _burn(msg.sender, noId, stakeNo);
                totalPayout += _calcPayout(c, stakeNo, 1);
            }
        }

        if (totalPayout > 0) {
            require(
                collateralToken.transfer(msg.sender, totalPayout),
                "payout transfer failed"
            );
        }
        emit PayoutRedemption(
            msg.sender,
            collateralToken,
            conditionId,
            totalPayout
        );
    }
}
