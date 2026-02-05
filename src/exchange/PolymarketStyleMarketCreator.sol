// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IOptimisticOracleV2, Request} from "./interfaces/IOptimisticOracleV2.sol";
import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";

/**
 * @title PolymarketStyleMarketCreator
 * @dev 修正后的市场创建者合约，使用正确的 UMA OptimisticOracleV2 接口
 */
contract PolymarketStyleMarketCreator is Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // ========== 常量 ==========
    uint64 public constant DEFAULT_LIVENESS = 7200; // 2小时（测试用，生产环境建议2天）
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant YES_NO_IDENTIFIER = bytes32("YES_OR_NO_QUERY");
    uint256 public constant OUTCOME_SLOT_COUNT = 2;
    uint256 public constant ANSWER_YES = 1e6; // 表示"是"
    uint256 public constant ANSWER_NO = 0; // 表示"否"

    // ========== 状态变量 ==========
    IConditionalTokens public immutable CONDITIONAL_TOKENS;
    /// @notice 可由 owner 更新的 UMA OptimisticOracleV2 合约地址（用于更换网络/升级）。
    IOptimisticOracleV2 public umaOracle;
    IERC20 public immutable COLLATERAL_TOKEN;

    event UmaOracleUpdated(
        address indexed oldOracle,
        address indexed newOracle
    );

    // 市场状态枚举
    enum MarketStatus {
        Active, // 0: 活跃中，可交易
        Requested, // 1: 已请求UMA裁决
        Proposed, // 2: 价格已提议
        Disputed, // 3: 价格被争议
        Settled, // 4: UMA已结算
        Resolved // 5: ConditionalTokens已解析
    }

    // 市场结构
    struct Market {
        bytes32 conditionId;
        bytes32 questionId;
        address creator;
        uint256 creationTime;
        uint256 umaRequestTime;
        MarketStatus status;
        uint256[] payoutNumerators;
        string questionText;
        bytes32 umaIdentifier;
        bool refundOnDispute;
    }

    // 存储映射
    mapping(bytes32 => Market) public markets; // questionId -> Market
    mapping(bytes32 => bool) public usedQuestionIds;
    EnumerableSet.Bytes32Set private activeMarkets;

    // ========== 事件 ==========
    event MarketCreated(
        bytes32 indexed conditionId,
        bytes32 indexed questionId,
        address creator,
        string metadataURI,
        uint256 timestamp
    );

    event PriceRequested(
        bytes32 indexed questionId,
        address requester,
        uint256 bondAmount,
        uint256 timestamp
    );

    event PriceProposed(
        bytes32 indexed questionId,
        int256 proposedPrice,
        address proposer,
        uint256 timestamp
    );

    event PriceDisputed(
        bytes32 indexed questionId,
        address disputer,
        uint256 timestamp
    );

    event MarketSettled(
        bytes32 indexed questionId,
        int256 resolvedPrice,
        uint256 payout,
        uint256 timestamp
    );

    event MarketResolved(
        bytes32 indexed conditionId,
        bytes32 indexed questionId,
        uint256[] payoutNumerators,
        address resolver,
        uint256 timestamp
    );

    event BondReturned(
        address indexed recipient,
        uint256 amount,
        bytes32 questionId
    );

    event MarketStatusChanged(
        bytes32 indexed questionId,
        MarketStatus oldStatus,
        MarketStatus newStatus
    );

    // ========== 构造函数 ==========
    constructor(
        address _conditionalTokens,
        address _umaOracle,
        address _collateralToken
    ) Ownable(msg.sender) {
        require(
            _conditionalTokens != address(0),
            "Invalid ConditionalTokens address"
        );
        require(_umaOracle != address(0), "Invalid UMA Oracle address");
        require(
            _collateralToken != address(0),
            "Invalid collateral token address"
        );

        CONDITIONAL_TOKENS = IConditionalTokens(_conditionalTokens);
        umaOracle = IOptimisticOracleV2(_umaOracle);
        COLLATERAL_TOKEN = IERC20(_collateralToken);
    }

    /// @notice 更新 UMA OptimisticOracleV2 地址。
    /// @dev 仅 owner 可调用；更新后影响 request/propose/dispute/settle 等所有 UMA 交互。
    function setUmaOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), "Invalid UMA Oracle address");
        address old = address(umaOracle);
        umaOracle = IOptimisticOracleV2(newOracle);
        emit UmaOracleUpdated(old, newOracle);
    }

    // ========== 外部函数 ==========

    /**
     * @dev 创建新的二元预测市场
     * @param questionText 市场元数据URI
     * @return conditionId 生成的条件ID
     * @return questionId 生成的问题ID
     */
    function createMarket(
        string calldata questionText
    ) external nonReentrant returns (bytes32 conditionId, bytes32 questionId) {
        require(bytes(questionText).length > 0, "Question text required");

        // 生成唯一的questionId
        questionId = keccak256(
            abi.encodePacked(
                questionText,
                block.timestamp,
                msg.sender,
                block.chainid
            )
        );
        require(!usedQuestionIds[questionId], "Question ID already used");
        usedQuestionIds[questionId] = true;

        // 使用指定的UMA标识符或默认值
        bytes32 identifier = YES_NO_IDENTIFIER;

        // 在 ConditionalTokens 中准备条件（prepareCondition 无返回值）
        CONDITIONAL_TOKENS.prepareCondition(
            address(umaOracle),
            questionId,
            OUTCOME_SLOT_COUNT
        );

        // 通过 helper 计算 conditionId
        conditionId = CONDITIONAL_TOKENS.getConditionId(
            address(umaOracle),
            questionId,
            OUTCOME_SLOT_COUNT
        );

        // 初始化赔付数组（全为0，表示未解决）
        uint256[] memory payoutNumerators = new uint256[](OUTCOME_SLOT_COUNT);
        payoutNumerators[0] = 0; // 第一个结果（索引0）
        payoutNumerators[1] = 0; // 第二个结果（索引1）

        // 存储市场信息
        markets[questionId] = Market({
            conditionId: conditionId,
            questionId: questionId,
            creator: msg.sender,
            creationTime: block.timestamp,
            umaRequestTime: 0,
            status: MarketStatus.Active,
            payoutNumerators: payoutNumerators,
            questionText: questionText,
            umaIdentifier: identifier,
            refundOnDispute: false
        });

        activeMarkets.add(questionId);

        emit MarketCreated(
            conditionId,
            questionId,
            msg.sender,
            questionText,
            block.timestamp
        );

        return (conditionId, questionId);
    }

    /**
     * @dev 请求UMA裁决市场
     * @param questionId 市场问题ID
     * @param bondAmount 保证金金额
     */
    function requestUmaResolution(
        bytes32 questionId,
        uint256 bondAmount
    ) external nonReentrant {
        Market storage market = markets[questionId];
        require(
            market.creator == msg.sender || msg.sender == owner(),
            "Not authorized"
        );
        require(market.status == MarketStatus.Active, "Market not active");

        // 将抵押品转入合约作为保证金
        if (bondAmount > 0) {
            require(
                COLLATERAL_TOKEN.transferFrom(
                    msg.sender,
                    address(this),
                    bondAmount
                ),
                "Bond transfer failed"
            );
        }

        // 步骤1: 请求UMA价格
        market.umaRequestTime = block.timestamp;
        uint256 totalBond = umaOracle.requestPrice(
            market.umaIdentifier,
            uint64(market.creationTime),
            _encodeAncillaryData(market.questionId, market.questionText),
            COLLATERAL_TOKEN,
            bondAmount
        );

        // 更新市场状态
        _updateMarketStatus(questionId, MarketStatus.Requested);

        emit PriceRequested(questionId, msg.sender, totalBond, block.timestamp);
    }

    /**
     * @dev 提议市场价格（通常在请求后立即调用）
     * @param questionId 市场问题ID
     * @param proposedAnswer 提议的答案（1e6=是，0=否）
     */
    function proposeMarketPrice(
        bytes32 questionId,
        int256 proposedAnswer
    ) external nonReentrant {
        Market storage market = markets[questionId];
        require(
            market.status == MarketStatus.Requested ||
                market.status == MarketStatus.Active,
            "Invalid status for proposal"
        );

        // 验证提议者权限
        require(
            msg.sender == market.creator || msg.sender == owner(),
            "Only creator or owner can propose"
        );

        // 步骤2: 提议价格
        umaOracle.proposePrice(
            address(this),
            market.umaIdentifier,
            uint64(market.creationTime),
            _encodeAncillaryData(market.questionId, market.questionText),
            proposedAnswer
        );

        // 更新市场状态
        _updateMarketStatus(questionId, MarketStatus.Proposed);

        emit PriceProposed(
            questionId,
            proposedAnswer,
            msg.sender,
            block.timestamp
        );
    }

    /**
     * @dev 结算UMA请求并解析市场
     * @param questionId 市场问题ID
     */
    function settleAndResolveMarket(bytes32 questionId) external nonReentrant {
        Market storage market = markets[questionId];
        require(
            market.status == MarketStatus.Proposed ||
                market.status == MarketStatus.Disputed,
            "Market not ready for settlement"
        );

        // 步骤3: 结算UMA请求
        uint256 payout = umaOracle.settle(
            address(this),
            market.umaIdentifier,
            uint64(market.creationTime),
            _encodeAncillaryData(market.questionId, market.questionText)
        );

        // 获取解决的价格
        int256 resolvedPrice = umaOracle.settleAndGetPrice(
            market.umaIdentifier,
            uint64(market.creationTime),
            _encodeAncillaryData(market.questionId, market.questionText)
        );

        // 更新市场状态
        _updateMarketStatus(questionId, MarketStatus.Settled);

        emit MarketSettled(questionId, resolvedPrice, payout, block.timestamp);

        // 根据解决的价格设置赔付数组
        uint256[] memory payoutNumerators = new uint256[](OUTCOME_SLOT_COUNT);

        // forge-lint: disable-next-line(unsafe-typecast)
        if (resolvedPrice == int256(ANSWER_YES)) {
            // "是"获胜
            payoutNumerators[0] = 0;
            payoutNumerators[1] = 1e6;
            // forge-lint: disable-next-line(unsafe-typecast)
        } else if (resolvedPrice == int256(ANSWER_NO)) {
            // "否"获胜
            payoutNumerators[0] = 1e6;
            payoutNumerators[1] = 0;
        } else {
            // 平局或其他（根据需求处理）
            payoutNumerators[0] = 5e5; // 各50%
            payoutNumerators[1] = 5e5;
        }

        // 步骤4: 解析ConditionalTokens条件
        _resolveMarketCondition(questionId, payoutNumerators);
    }

    /**
     * @dev 争议提议的价格
     * @param questionId 市场问题ID
     */
    function disputeMarketPrice(bytes32 questionId) external nonReentrant {
        Market storage market = markets[questionId];
        require(market.status == MarketStatus.Proposed, "Market not proposed");
        require(!market.refundOnDispute, "Refund on dispute enabled");

        // 争议价格
        umaOracle.disputePrice(
            address(this),
            market.umaIdentifier,
            uint64(market.creationTime),
            _encodeAncillaryData(market.questionId, market.questionText)
        );

        // 更新市场状态
        _updateMarketStatus(questionId, MarketStatus.Disputed);

        emit PriceDisputed(questionId, msg.sender, block.timestamp);
    }

    /**
     * @dev 手动解析市场（管理员后备）
     * @param questionId 市场问题ID
     * @param payoutNumerators 赔付数组
     */
    function forceResolveMarket(
        bytes32 questionId,
        uint256[] calldata payoutNumerators
    ) external onlyOwner {
        Market storage market = markets[questionId];
        require(
            market.status != MarketStatus.Resolved,
            "Market already resolved"
        );
        require(
            payoutNumerators.length == OUTCOME_SLOT_COUNT,
            "Invalid payout length"
        );

        _resolveMarketCondition(questionId, payoutNumerators);
    }

    // ========== 视图函数 ==========

    /**
     * @dev 检查UMA请求是否可结算
     */
    function canSettle(bytes32 questionId) public view returns (bool) {
        Market storage market = markets[questionId];

        // 获取请求详情
        Request memory request = umaOracle.getRequest(
            address(this),
            market.umaIdentifier,
            uint64(market.creationTime),
            _encodeAncillaryData(market.questionId, market.questionText)
        );

        // 检查是否已解决且未结算
        return request.settled && market.status != MarketStatus.Settled;
    }

    /**
     * @dev 获取UMA请求详情
     */
    function getUmaRequest(
        bytes32 questionId
    ) external view returns (Request memory) {
        Market storage market = markets[questionId];
        return
            umaOracle.getRequest(
                address(this),
                market.umaIdentifier,
                uint64(market.creationTime),
                _encodeAncillaryData(market.questionId, market.questionText)
            );
    }

    /**
     * @dev 获取collectionId
     */
    function getCollectionId(
        bytes32 questionId,
        uint256 indexSet
    ) public view returns (bytes32) {
        Market storage market = markets[questionId];
        bytes32 parentCollectionId = bytes32(0);

        return
            CONDITIONAL_TOKENS.getCollectionId(
                parentCollectionId,
                market.conditionId,
                indexSet
            );
    }

    /**
     * @dev 获取positionId
     */
    function getPositionId(
        bytes32 questionId,
        uint256 indexSet
    ) public view returns (uint256) {
        bytes32 collectionId = getCollectionId(questionId, indexSet);
        return CONDITIONAL_TOKENS.getPositionId(COLLATERAL_TOKEN, collectionId);
    }

    /**
     * @dev 获取市场详情
     */
    function getMarketDetails(
        bytes32 questionId
    )
        external
        view
        returns (
            bytes32 conditionId,
            address creator,
            uint256 creationTime,
            MarketStatus status,
            uint256[] memory payoutNumerators,
            string memory metadataURI,
            bytes32 umaIdentifier,
            bool isResolved
        )
    {
        Market storage market = markets[questionId];
        // IConditionalTokens 接口不包含 isResolved（ConditionalTokens 原版也没有这个方法）。
        // 市场是否已解析可由 market.status 判断：Resolved 表示已通过 reportPayouts 上报。
        isResolved = (market.status == MarketStatus.Resolved);

        return (
            market.conditionId,
            market.creator,
            market.creationTime,
            market.status,
            market.payoutNumerators,
            market.questionText,
            market.umaIdentifier,
            isResolved
        );
    }

    /**
     * @dev 获取活跃市场列表
     */
    function getActiveMarkets() external view returns (bytes32[] memory) {
        return activeMarkets.values();
    }

    /**
     * @dev 获取市场数量
     */
    function getMarketCount() external view returns (uint256) {
        return activeMarkets.length();
    }

    // ========== 内部函数 ==========

    /**
     * @dev 解析市场条件
     */
    function _resolveMarketCondition(
        bytes32 questionId,
        uint256[] memory payoutNumerators
    ) internal {
        Market storage market = markets[questionId];

        // 在ConditionalTokens中报告赔付
        // IConditionalTokens.reportPayouts 的参数为 questionId
        CONDITIONAL_TOKENS.reportPayouts(market.questionId, payoutNumerators);

        // 更新市场信息
        market.payoutNumerators = payoutNumerators;
        _updateMarketStatus(questionId, MarketStatus.Resolved);

        // 从活跃市场列表中移除
        activeMarkets.remove(questionId);

        emit MarketResolved(
            market.conditionId,
            market.questionId,
            payoutNumerators,
            msg.sender,
            block.timestamp
        );
    }

    /**
     * @dev 更新市场状态
     */
    function _updateMarketStatus(
        bytes32 questionId,
        MarketStatus newStatus
    ) internal {
        Market storage market = markets[questionId];
        MarketStatus oldStatus = market.status;
        market.status = newStatus;

        emit MarketStatusChanged(questionId, oldStatus, newStatus);
    }

    /**
     * @dev 编码辅助数据
     */
    function _encodeAncillaryData(
        bytes32 questionId,
        string memory metadataURI
    ) internal pure returns (bytes memory) {
        return abi.encode(questionId, metadataURI);
    }

    // ========== 管理员函数 ==========

    /**
     * @dev 设置UMA标识符
     */
    function setUmaIdentifier(
        bytes32 questionId,
        bytes32 newIdentifier
    ) external onlyOwner {
        Market storage market = markets[questionId];
        require(market.status == MarketStatus.Active, "Market not active");
        market.umaIdentifier = newIdentifier;
    }

    /**
     * @dev 设置争议退款
     */
    function setRefundOnDispute(
        bytes32 questionId,
        bool refund
    ) external onlyOwner {
        Market storage market = markets[questionId];
        market.refundOnDispute = refund;
        // 注意：UMA 的 refundOnDispute 是按具体 request (identifier/timestamp/ancillaryData) 设置的，
        // 且本项目的 IOptimisticOracleV2 接口未暴露该方法。
        // 这里仅记录配置，实际在 requestUmaResolution 时可根据该值选择是否调用 UMA 的对应设置接口。
    }

    /**
     * @dev 设置自定义活跃期
     */
    function setCustomLiveness(
        bytes32 questionId,
        uint256 customLiveness
    ) external onlyOwner {
        Market storage market = markets[questionId];

        umaOracle.setCustomLiveness(
            market.umaIdentifier,
            uint64(market.creationTime),
            _encodeAncillaryData(market.questionId, market.questionText),
            customLiveness
        );
    }

    /**
     * @dev 提取意外发送的代币
     */
    function recoverTokens(address token, uint256 amount) external onlyOwner {
        require(
            token != address(COLLATERAL_TOKEN),
            "Cannot recover collateral"
        );
        require(IERC20(token).transfer(owner(), amount), "Transfer failed");
    }
}
