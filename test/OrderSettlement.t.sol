// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {OrderSettlement} from "../src/exchange/OrderSettlement.sol";
import {MinimalConditionalTokens} from "../src/exchange/MinimalConditionalTokens.sol";
import {MockERC20} from "../src/exchange/MockERC20.sol";

/// @notice 单测：订单交易合约（撮合结算合约）
contract OrderSettlement_Test is Test {
    MinimalConditionalTokens ct;
    MockERC20 usdc;
    OrderSettlement ex;

    address oracle = address(0xBEEF);

    uint256 makerSk;
    address maker;
    address taker;

    bytes32 q;
    bytes32 conditionId;
    uint256 yesId;

    function setUp() external {
        makerSk = 0xA11CE;
        maker = vm.addr(makerSk);
        taker = address(0xB0B);

        ct = new MinimalConditionalTokens(oracle);
        usdc = new MockERC20("Mock USDC", "mUSDC");
        ex = new OrderSettlement("CTFMarket-OrderSettlement", "1");

        // prepare YES/NO condition
        q = keccak256("order-settlement-test");
        ct.prepareCondition(oracle, q, 2);
        conditionId = ct.getConditionId(oracle, q, 2);

        yesId = ct.getPositionId(
            usdc,
            ct.getCollectionId(bytes32(0), conditionId, 1)
        );

        // maker gets YES positions by splitting collateral
        usdc.mint(maker, 1_000e6);
        vm.startPrank(maker);
        usdc.approve(address(ct), type(uint256).max);
        ct.splitPosition2(
            usdc,
            bytes32(0),
            conditionId,
            MinimalConditionalTokens.SplitKind.YES_ONLY,
            600e6
        );
        // maker approves exchange to move ERC1155 positions
        ct.setApprovalForAll(address(ex), true);
        vm.stopPrank();

        // taker has USDC for payment
        usdc.mint(taker, 1_000e6);
        vm.prank(taker);
        usdc.approve(address(ex), type(uint256).max);
    }

    function _order(
        uint256 amount,
        uint256 priceE6,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (OrderSettlement.Order memory o) {
        o = OrderSettlement.Order({
            conditionalTokens: address(ct),
            collateralToken: address(usdc),
            positionId: yesId,
            amount: amount,
            priceE6: priceE6,
            maker: maker,
            nonce: nonce,
            deadline: deadline
        });
    }

    function _sign(OrderSettlement.Order memory o) internal returns (bytes memory sig) {
        bytes32 orderHash = ex.hashOrder(o);
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", ex.DOMAIN_SEPARATOR(), orderHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerSk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function test_fillOrder_fullFill_transfersCorrectly() external {
        OrderSettlement.Order memory o = _order({
            amount: 100e6,
            priceE6: 500_000, // 0.5 USDC per share
            nonce: 1,
            deadline: block.timestamp + 1 days
        });
        bytes memory sig = _sign(o);

        uint256 beforeMakerUsdc = usdc.balanceOf(maker);
        uint256 beforeTakerUsdc = usdc.balanceOf(taker);
        uint256 beforeMakerYes = ct.balanceOf(maker, yesId);
        uint256 beforeTakerYes = ct.balanceOf(taker, yesId);

        vm.prank(taker);
        uint256 cost = ex.fillOrder(o, 100e6, sig);

        assertEq(cost, (100e6 * 500_000) / 1e6, "cost mismatch");
        assertEq(usdc.balanceOf(maker), beforeMakerUsdc + cost, "maker usdc");
        assertEq(usdc.balanceOf(taker), beforeTakerUsdc - cost, "taker usdc");

        assertEq(ct.balanceOf(maker, yesId), beforeMakerYes - 100e6, "maker yes");
        assertEq(ct.balanceOf(taker, yesId), beforeTakerYes + 100e6, "taker yes");

        bytes32 h = ex.hashOrder(o);
        assertEq(ex.filled(h), 100e6, "filled");
        assertTrue(ex.nonceUsed(maker, 1), "nonce should be used after full fill");
    }

    function test_fillOrder_partialFill_thenFillRest() external {
        OrderSettlement.Order memory o = _order({
            amount: 100e6,
            priceE6: 1_000_000,
            nonce: 2,
            deadline: block.timestamp + 1 days
        });
        bytes memory sig = _sign(o);

        vm.prank(taker);
        ex.fillOrder(o, 40e6, sig);

        bytes32 h = ex.hashOrder(o);
        assertEq(ex.filled(h), 40e6);
        assertFalse(ex.nonceUsed(maker, 2));

        vm.prank(taker);
        ex.fillOrder(o, 60e6, sig);

        assertEq(ex.filled(h), 100e6);
        assertTrue(ex.nonceUsed(maker, 2));
    }

    function test_cancelNonce_blocksFill() external {
        OrderSettlement.Order memory o = _order({
            amount: 10e6,
            priceE6: 1_000_000,
            nonce: 3,
            deadline: block.timestamp + 1 days
        });
        bytes memory sig = _sign(o);

        vm.prank(maker);
        ex.cancelNonce(3);

        vm.prank(taker);
        vm.expectRevert(OrderSettlement.NonceUsed.selector);
        ex.fillOrder(o, 1e6, sig);
    }

    function test_expiredOrder_reverts() external {
        OrderSettlement.Order memory o = _order({
            amount: 10e6,
            priceE6: 1_000_000,
            nonce: 4,
            deadline: block.timestamp - 1
        });
        bytes memory sig = _sign(o);

        vm.prank(taker);
        vm.expectRevert(OrderSettlement.ExpiredOrder.selector);
        ex.fillOrder(o, 1e6, sig);
    }

    function test_invalidSignature_reverts() external {
        OrderSettlement.Order memory o = _order({
            amount: 10e6,
            priceE6: 1_000_000,
            nonce: 5,
            deadline: block.timestamp + 1 days
        });

        // sign with wrong key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBEEF, keccak256("bad"));
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(taker);
        vm.expectRevert(OrderSettlement.InvalidSignature.selector);
        ex.fillOrder(o, 1e6, sig);
    }
}
