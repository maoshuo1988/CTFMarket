// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";

/// @notice 统一市场合约（方案1）：
/// - 用户真实持有 ConditionalTokens 的 ERC1155 头寸（YES/NO 可转让）
/// - 本合约只做“市场创建 + 做市商卖出 + 用户间撮合 + 决议(上报 payout)”
/// - 结算赎回由用户直接调用 CT.redeemPositions 完成
///
/// @dev 满足 README 的主流程表达，并避免“内部账本需要遍历用户统计总份额”的问题。
contract UnifiedMarket is Ownable, ReentrancyGuard {
    error MarketNotFound();
    error MarketResolved();
    error InvalidOutcome();
    error InvalidPrice();
    error OrderNotOpen();
    error NotOrderMaker();
    error InsufficientAmount();
    error EmptyQuestion();
    error ZeroLiquidity();
    error MarketExists();
    error LenMustBe2();
    error PayoutAllZero();
    error SharesZero();
    error AmountZero();

    event MarketCreated(
        bytes32 indexed marketId,
        bytes32 indexed questionId,
        bytes32 indexed conditionId,
        address maker
    );
    event BoughtFromMaker(
        bytes32 indexed marketId,
        address indexed buyer,
        uint8 outcome,
        uint256 shares,
        uint256 cost
    );
    event OrderCreated(
        uint256 indexed orderId,
        bytes32 indexed marketId,
        address indexed maker,
        uint8 outcome,
        uint256 amount,
        uint256 priceE6
    );
    event OrderFilled(
        uint256 indexed orderId,
        address indexed taker,
        uint256 amount,
        uint256 cost
    );
    event MarketResolvedEvent(bytes32 indexed marketId, uint256[] payouts);

    struct Market {
        bytes32 marketId;
        bytes32 questionId;
        bytes32 conditionId;
        address maker;
        bool resolved;
        uint256 yesPositionId;
        uint256 noPositionId;
    }

    struct Order {
        bytes32 marketId;
        address maker;
        uint8 outcome; // 0 yes, 1 no (maker sells this)
        uint256 amountRemaining;
        uint256 priceE6;
        bool open;
    }

    IERC20 public immutable collateralToken;
    IConditionalTokens public immutable conditionalTokens;
    address public immutable oracle;

    mapping(bytes32 => Market) public markets;
    uint256 public nextOrderId = 1;
    mapping(uint256 => Order) public orders;

    constructor(
        address conditionalTokens_,
        address collateralToken_,
        address oracle_
    ) Ownable(msg.sender) {
        require(
            conditionalTokens_ != address(0) &&
                collateralToken_ != address(0) &&
                oracle_ != address(0),
            "zero"
        );
        conditionalTokens = IConditionalTokens(conditionalTokens_);
        collateralToken = IERC20(collateralToken_);
        oracle = oracle_;
    }

    /// @notice 做市商创建市场：prepareCondition，并在自己地址 split 全头寸（YES+NO）。
    /// @param questionText 仅用来生成 questionId
    /// @param initialLiquidity 铸造的份额数量（YES=initialLiquidity, NO=initialLiquidity）
    function createMarket(
        string calldata questionText,
        uint256 initialLiquidity
    )
        external
        nonReentrant
        returns (bytes32 marketId, bytes32 questionId, bytes32 conditionId)
    {
        if (bytes(questionText).length == 0) revert EmptyQuestion();
        if (initialLiquidity == 0) revert ZeroLiquidity();

        questionId = keccak256(
            abi.encodePacked(
                questionText,
                block.timestamp,
                msg.sender,
                block.chainid
            )
        );
        conditionId = conditionalTokens.getConditionId(oracle, questionId, 2);
        marketId = keccak256(abi.encodePacked(conditionId, msg.sender));
        if (markets[marketId].maker != address(0)) revert MarketExists();

        conditionalTokens.prepareCondition(oracle, questionId, 2);

        // 做市商在自己地址 split：需要事先对 CT 授权 collateral
        require(
            collateralToken.transferFrom(
                msg.sender,
                address(this),
                initialLiquidity
            ),
            "collateral pull failed"
        );
        collateralToken.approve(address(conditionalTokens), initialLiquidity);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        conditionalTokens.splitPosition(
            collateralToken,
            bytes32(0),
            conditionId,
            partition,
            initialLiquidity
        );

        // 将刚铸造在本合约的 YES/NO 头寸转回给 maker（maker 才是流动性提供者）
        uint256 yesId = conditionalTokens.getPositionId(
            collateralToken,
            conditionalTokens.getCollectionId(bytes32(0), conditionId, 1)
        );
        uint256 noId = conditionalTokens.getPositionId(
            collateralToken,
            conditionalTokens.getCollectionId(bytes32(0), conditionId, 2)
        );
        conditionalTokens.safeTransferFrom(
            address(this),
            msg.sender,
            yesId,
            initialLiquidity,
            ""
        );
        conditionalTokens.safeTransferFrom(
            address(this),
            msg.sender,
            noId,
            initialLiquidity,
            ""
        );

        markets[marketId] = Market({
            marketId: marketId,
            questionId: questionId,
            conditionId: conditionId,
            maker: msg.sender,
            resolved: false,
            yesPositionId: yesId,
            noPositionId: noId
        });

        emit MarketCreated(marketId, questionId, conditionId, msg.sender);
    }

    /// @notice 从做市商买入 outcome 头寸。
    /// @dev 这里简化为“1 USDC -> 1 share”的直购，用于与文档场景的 stake 概念对齐。
    ///      maker 需要预先在 CT 上对本合约 setApprovalForAll。
    function buyFromMaker(
        bytes32 marketId,
        uint8 outcome,
        uint256 shares
    ) external nonReentrant {
        if (outcome > 1) revert InvalidOutcome();
        Market storage m = markets[marketId];
        if (m.maker == address(0)) revert MarketNotFound();
        if (m.resolved) revert MarketResolved();
        if (shares == 0) revert SharesZero();

        uint256 cost = shares; // 1:1 简化
        require(
            collateralToken.transferFrom(msg.sender, m.maker, cost),
            "pay failed"
        );

        uint256 positionId = outcome == 0 ? m.yesPositionId : m.noPositionId;
        conditionalTokens.safeTransferFrom(
            m.maker,
            msg.sender,
            positionId,
            shares,
            ""
        );

        emit BoughtFromMaker(marketId, msg.sender, outcome, shares, cost);
    }

    /// @notice 挂单：卖出某一侧头寸，按 priceE6(1e6=1 USDC)计价。
    /// @dev maker 需提前 setApprovalForAll 给本合约。
    function createLimitOrder(
        bytes32 marketId,
        uint8 outcome,
        uint256 amount,
        uint256 priceE6
    ) external nonReentrant returns (uint256 orderId) {
        if (outcome > 1) revert InvalidOutcome();
        if (priceE6 == 0) revert InvalidPrice();
        Market storage m = markets[marketId];
        if (m.maker == address(0)) revert MarketNotFound();
        if (m.resolved) revert MarketResolved();
        if (amount == 0) revert AmountZero();

        // 托管卖方的 ERC1155 头寸到本合约
        uint256 positionId = outcome == 0 ? m.yesPositionId : m.noPositionId;
        conditionalTokens.safeTransferFrom(
            msg.sender,
            address(this),
            positionId,
            amount,
            ""
        );

        orderId = nextOrderId;
        unchecked {
            nextOrderId = orderId + 1;
        }
        orders[orderId] = Order({
            marketId: marketId,
            maker: msg.sender,
            outcome: outcome,
            amountRemaining: amount,
            priceE6: priceE6,
            open: true
        });
        emit OrderCreated(
            orderId,
            marketId,
            msg.sender,
            outcome,
            amount,
            priceE6
        );
    }

    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (!o.open) revert OrderNotOpen();
        if (o.maker != msg.sender) revert NotOrderMaker();

        o.open = false;

        if (o.amountRemaining > 0) {
            Market storage m = markets[o.marketId];
            uint256 positionId = o.outcome == 0
                ? m.yesPositionId
                : m.noPositionId;
            conditionalTokens.safeTransferFrom(
                address(this),
                msg.sender,
                positionId,
                o.amountRemaining,
                ""
            );
            o.amountRemaining = 0;
        }
    }

    /// @notice 吃单购买 amount 份（若 amount=0 则全吃）。
    function acceptOrder(
        uint256 orderId,
        uint256 amount
    ) external nonReentrant {
        Order storage o = orders[orderId];
        if (!o.open) revert OrderNotOpen();
        Market storage m = markets[o.marketId];
        if (m.resolved) revert MarketResolved();

        uint256 fill = amount == 0 ? o.amountRemaining : amount;
        if (fill == 0 || fill > o.amountRemaining) revert InsufficientAmount();

        uint256 cost = (fill * o.priceE6) / 1e6;
        require(
            collateralToken.transferFrom(msg.sender, o.maker, cost),
            "usdc transfer failed"
        );

        uint256 positionId = o.outcome == 0 ? m.yesPositionId : m.noPositionId;
        conditionalTokens.safeTransferFrom(
            address(this),
            msg.sender,
            positionId,
            fill,
            ""
        );

        o.amountRemaining -= fill;
        if (o.amountRemaining == 0) o.open = false;

        emit OrderFilled(orderId, msg.sender, fill, cost);
    }

    /// @notice 决议市场（owner）：直接透传到 CT.reportPayouts。
    function resolveMarket(
        bytes32 marketId,
        uint256[] calldata payouts
    ) external onlyOwner nonReentrant {
        Market storage m = markets[marketId];
        if (m.maker == address(0)) revert MarketNotFound();
        if (m.resolved) revert MarketResolved();
        if (payouts.length != 2) revert LenMustBe2();
        if (payouts[0] + payouts[1] == 0) revert PayoutAllZero();

        conditionalTokens.reportPayouts(m.questionId, payouts);
        m.resolved = true;
        emit MarketResolvedEvent(marketId, payouts);
    }

    function getPositionIds(
        bytes32 marketId
    ) external view returns (uint256 yesId, uint256 noId) {
        Market storage m = markets[marketId];
        if (m.maker == address(0)) revert MarketNotFound();
        return (m.yesPositionId, m.noPositionId);
    }
}
