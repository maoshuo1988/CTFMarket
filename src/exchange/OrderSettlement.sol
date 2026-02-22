// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";

/// @notice 订单交易合约（撮合结算合约）：
/// - maker 离线签名挂单（EIP-712）出售某个 outcome 头寸（ERC1155 position token）
/// - taker 链上填单：支付 ERC20 -> 得到 ERC1155 头寸
/// - 链上维护 filled/nonceUsed，防止重放、支持部分成交
///
/// @dev 设计目标：满足 docs/ALOGEDESIGN_功能清单与方案设计.md 中“方案A：纯撮合结果结算合约”的最小可用版本。
///      当前仓库的 ConditionalTokens(MinimalConditionalTokens) 已经是可转让 ERC1155，因此结算只需要做 ERC1155 转移。
contract OrderSettlement {
    using ECDSA for bytes32;

    error InvalidSignature();
    error ExpiredOrder();
    error NonceUsed();
    error InvalidAmount();
    error InsufficientRemaining();
    error TransferFailed();

    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed taker,
        uint256 fillAmount,
        uint256 cost
    );

    event OrderCancelled(address indexed maker, uint256 indexed nonce);

    struct Order {
        // what is being sold
        address conditionalTokens; // ERC1155 positions contract
        address collateralToken; // ERC20 used for payment
        uint256 positionId; // ERC1155 token id

        // economics
        uint256 amount; // total amount of position to sell
        uint256 priceE6; // cost per 1 unit position, with 1e6 precision

        // validity
        address maker;
        uint256 nonce;
        uint256 deadline; // unix timestamp
    }

    bytes32 public immutable DOMAIN_SEPARATOR;
    uint256 public immutable CHAIN_ID;

    bytes32 public constant ORDER_TYPEHASH =
        keccak256(
            "Order(address conditionalTokens,address collateralToken,uint256 positionId,uint256 amount,uint256 priceE6,address maker,uint256 nonce,uint256 deadline)"
        );

    // maker => nonce => used?
    mapping(address => mapping(uint256 => bool)) public nonceUsed;

    // orderHash => filled amount
    mapping(bytes32 => uint256) public filled;

    constructor(string memory name, string memory version) {
        CHAIN_ID = block.chainid;
        DOMAIN_SEPARATOR = _buildDomainSeparator(name, version);
    }

    function _buildDomainSeparator(
        string memory name,
        string memory version
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                    ),
                    keccak256(bytes(name)),
                    keccak256(bytes(version)),
                    block.chainid,
                    address(this)
                )
            );
    }

    function hashOrder(Order memory o) public pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    o.conditionalTokens,
                    o.collateralToken,
                    o.positionId,
                    o.amount,
                    o.priceE6,
                    o.maker,
                    o.nonce,
                    o.deadline
                )
            );
    }

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function remaining(Order memory o) public view returns (uint256) {
        bytes32 orderHash = hashOrder(o);
        uint256 f = filled[orderHash];
        if (f >= o.amount) return 0;
        return o.amount - f;
    }

    /// @notice maker 取消某个 nonce，后续所有相同 maker+nonce 的订单都会被视为不可用。
    function cancelNonce(uint256 nonce) external {
        nonceUsed[msg.sender][nonce] = true;
        emit OrderCancelled(msg.sender, nonce);
    }

    /// @notice 填单（可部分成交）。
    /// @dev 前置条件：
    /// - maker 已对 conditionalTokens setApprovalForAll(this, true)
    /// - taker 已对 collateralToken approve(this, ...)
    function fillOrder(
        Order calldata o,
        uint256 fillAmount,
        bytes calldata makerSig
    ) external returns (uint256 cost) {
        if (block.timestamp > o.deadline) revert ExpiredOrder();
        if (nonceUsed[o.maker][o.nonce]) revert NonceUsed();
        if (fillAmount == 0) revert InvalidAmount();

        bytes32 orderHash = hashOrder(o);
        uint256 f = filled[orderHash];
        if (f + fillAmount > o.amount) revert InsufficientRemaining();

        // verify signature
        bytes32 digest = _hashTypedData(orderHash);
        address signer = digest.recover(makerSig);
        if (signer != o.maker || signer == address(0)) revert InvalidSignature();

        // compute cost
        cost = (fillAmount * o.priceE6) / 1e6;

        // pull ERC20 from taker -> pay maker
        if (!IERC20(o.collateralToken).transferFrom(msg.sender, o.maker, cost)) {
            revert TransferFailed();
        }

        // transfer ERC1155 position from maker -> taker
        IConditionalTokens(o.conditionalTokens).safeTransferFrom(
            o.maker,
            msg.sender,
            o.positionId,
            fillAmount,
            ""
        );

        // update filled
        filled[orderHash] = f + fillAmount;
        if (filled[orderHash] == o.amount) {
            nonceUsed[o.maker][o.nonce] = true;
        }

        emit OrderFilled(orderHash, o.maker, msg.sender, fillAmount, cost);
    }
}
