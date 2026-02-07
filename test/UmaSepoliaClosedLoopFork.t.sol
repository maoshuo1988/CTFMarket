// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {UnifiedMarket} from "../src/exchange/UnifiedMarket.sol";
import {MinimalConditionalTokens} from "../src/exchange/MinimalConditionalTokens.sol";
import {MockERC20} from "../src/exchange/MockERC20.sol";
import {IOptimisticOracleV2} from "../src/exchange/interfaces/IOptimisticOracleV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Sepolia fork 闭环测试：UMA OOV2（链上真实合约）-> 本仓库 MinimalConditionalTokens。
///
/// 目标：把 `docs/UMA测试用例场景.md` 的 UMA 流程落实为可执行的 fork 测试：
/// - OOV2: requestPrice -> proposePrice -> settleAndGetPrice
/// - CT: prepareCondition -> splitPosition -> reportPayouts -> redeemPositions
///
/// 运行示例：
///   RPC_URL=... UNIFIED_MARKET=0x... forge test --match-contract UmaSepoliaClosedLoopForkTest --fork-url $RPC_URL -vvv
contract UmaSepoliaClosedLoopForkTest is Test {
    // UMA OptimisticOracleV2 on Sepolia (network/11155111.json)
    address constant UMA_OOV2_SEPOLIA =
        0x9f1263B8f0355673619168b5B8c0248f1d03e88C;

    // Common roles (no user-to-user transfers; only contract interactions)
    address constant MM = address(0x4D4D);
    address constant A = address(0xA);
    address constant B = address(0xB);
    address constant C = address(0xC);

    // UMA request params (keep it simple and stable)
    bytes32 constant IDENTIFIER = bytes32("YES_OR_NO_QUERY");
    bytes constant ANCILLARY = bytes("CTFMarket UMA closed-loop test");

    // Sepolia WETH (known to be on UMA CollateralWhitelist)
    // Checked via CollateralWhitelist.isOnWhitelist(WETH) == true
    address constant WETH_SEPOLIA = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;

    uint256 constant USDC_DECIMALS = 1e6;

    function setUp() external {
        // fork-only
        try vm.activeFork() returns (uint256) {
            // ok
        } catch {
            vm.skip(true);
        }
    }

    function _market() internal view returns (UnifiedMarket market) {
        market = UnifiedMarket(vm.envAddress("UNIFIED_MARKET"));
        require(market.oracle() == UMA_OOV2_SEPOLIA, "oracle mismatch");
    }

    function _contracts()
        internal
        view
        returns (
            UnifiedMarket market,
            MinimalConditionalTokens ct,
            MockERC20 usdc,
            IOptimisticOracleV2 oov2
        )
    {
        market = _market();
        ct = MinimalConditionalTokens(address(market.conditionalTokens()));
        usdc = MockERC20(address(market.collateralToken()));
        oov2 = IOptimisticOracleV2(UMA_OOV2_SEPOLIA);
    }

    function _prepare(
        MinimalConditionalTokens ct,
        bytes32 q
    ) internal returns (bytes32 conditionId) {
        ct.prepareCondition(UMA_OOV2_SEPOLIA, q, 2);
        conditionId = ct.getConditionId(UMA_OOV2_SEPOLIA, q, 2);
    }

    function _splitYes(
        MinimalConditionalTokens ct,
        MockERC20 usdc,
        bytes32 conditionId,
        address user,
        uint256 amount
    ) internal {
        vm.prank(user);
        ct.splitPosition2(
            usdc,
            bytes32(0),
            conditionId,
            MinimalConditionalTokens.SplitKind.YES_ONLY,
            amount
        );
    }

    function _splitNo(
        MinimalConditionalTokens ct,
        MockERC20 usdc,
        bytes32 conditionId,
        address user,
        uint256 amount
    ) internal {
        vm.prank(user);
        ct.splitPosition2(
            usdc,
            bytes32(0),
            conditionId,
            MinimalConditionalTokens.SplitKind.NO_ONLY,
            amount
        );
    }

    function _approve(MockERC20 usdc, address user, address spender) internal {
        vm.prank(user);
        usdc.approve(spender, type(uint256).max);
    }

    function _redeemYes(
        MinimalConditionalTokens ct,
        MockERC20 usdc,
        bytes32 conditionId,
        address user
    ) internal {
        vm.prank(user);
        ct.redeemPositions2(
            usdc,
            bytes32(0),
            conditionId,
            MinimalConditionalTokens.RedeemMask.wrap(1)
        );
    }

    function _redeemNo(
        MinimalConditionalTokens ct,
        MockERC20 usdc,
        bytes32 conditionId,
        address user
    ) internal {
        vm.prank(user);
        ct.redeemPositions2(
            usdc,
            bytes32(0),
            conditionId,
            MinimalConditionalTokens.RedeemMask.wrap(2)
        );
    }

    /// @dev 走 UMA OOV2 闭环（不 dispute）。
    /// - requester: 发起 requestPrice / settleAndGetPrice 的地址
    /// - proposer: proposePrice 提案人（需要持有并 approve bond token）
    /// Returns: resolvedPrice (int256).
    function _umaResolvePrice(
        IOptimisticOracleV2 oov2,
        address currency,
        address requester,
        address proposer,
        int256 price
    ) internal returns (int256) {
        uint256 ts = block.timestamp;

        // 1) request price (reward=0)
        vm.prank(requester);
        uint256 totalBond = oov2.requestPrice(
            IDENTIFIER,
            ts,
            ANCILLARY,
            IERC20(currency),
            0
        );

        // 2) proposer posts bond and proposes price
        // totalBond is the amount that proposePrice will pull.
        // fork 环境下直接给 proposer 准备 bond：用 deal 给 whitelist currency 打款
        deal(currency, proposer, totalBond);
        vm.prank(proposer);
        IERC20(currency).approve(address(oov2), type(uint256).max);

        vm.prank(proposer);
        oov2.proposePrice(requester, IDENTIFIER, ts, ANCILLARY, price);

        // 3) wait liveness and settle
        uint256 liveness = oov2.defaultLiveness();
        vm.warp(block.timestamp + liveness + 1);

        vm.prank(requester);
        int256 resolved = oov2.settleAndGetPrice(IDENTIFIER, ts, ANCILLARY);
        return resolved;
    }

    function _bridgeToCt(
        MinimalConditionalTokens ct,
        bytes32 q,
        bool yesWins
    ) internal {
        uint256[] memory payouts = new uint256[](2);
        if (yesWins) {
            payouts[0] = 1;
            payouts[1] = 0;
        } else {
            payouts[0] = 0;
            payouts[1] = 1;
        }
        vm.prank(UMA_OOV2_SEPOLIA);
        ct.reportPayouts(q, payouts);
    }

    function _q(bytes32 salt, address ct) internal pure returns (bytes32) {
        // 保证每个用例 Q 唯一，避免与其他测试/链上状态冲突
        return keccak256(abi.encodePacked("UMA-ARBITRAGE-Q1", salt, ct));
    }

    function _assertFinalBalance(
        MockERC20 usdc,
        address user,
        uint256 beforeBal,
        uint256 stake,
        uint256 expectedRedeem,
        string memory err
    ) internal view {
        uint256 afterBal = usdc.balanceOf(user);
        assertEq(afterBal, beforeBal - stake + expectedRedeem, err);
    }

    /// @notice 用例#001：A 押 YES 600，B 押 NO 400，UMA 结算 YES 胜 -> 写入 payout -> 赎回。
    /// 期望：A +400e6，B -400e6（忽略 gas）。
    function test_uma_case001_A_yes_B_no_yesWins_closedLoop() external {
        (
            UnifiedMarket market,
            MinimalConditionalTokens ct,
            MockERC20 usdc,
            IOptimisticOracleV2 oov2
        ) = _contracts();
        market; // silence unused warning

        // Mint from 0 and approve
        usdc.mint(A, 600 * USDC_DECIMALS);
        usdc.mint(B, 400 * USDC_DECIMALS);
        _approve(usdc, A, address(ct));
        _approve(usdc, B, address(ct));

        bytes32 q = _q(bytes32("case001"), address(ct));
        bytes32 conditionId = _prepare(ct, q);

        uint256 beforeA = usdc.balanceOf(A);
        uint256 beforeB = usdc.balanceOf(B);

        _splitYes(ct, usdc, conditionId, A, 600 * USDC_DECIMALS);
        vm.warp(block.timestamp + 30);
        _splitNo(ct, usdc, conditionId, B, 400 * USDC_DECIMALS);

        // UMA: propose YES(=1)
        int256 resolved = _umaResolvePrice(oov2, WETH_SEPOLIA, MM, MM, 1);
        assertEq(resolved, 1, "UMA resolved price should be 1");

        _bridgeToCt(ct, q, true);

        _redeemYes(ct, usdc, conditionId, A);
        _redeemNo(ct, usdc, conditionId, B);

        uint256 afterA = usdc.balanceOf(A);
        uint256 afterB = usdc.balanceOf(B);

        assertEq(afterA, beforeA + 400 * USDC_DECIMALS, "A should profit +400");
        assertEq(afterB, beforeB - 400 * USDC_DECIMALS, "B should lose -400");
    }

    /// @notice 用例#002：三方对赌（A/C 押 YES，B 押 NO），UMA 结算 YES 胜 -> 写入 payout -> 赎回。
    ///
    /// 按 `docs/UMA测试用例场景.md`：
    /// - A: 200, B: 300, C: 250，总池=750
    /// - YES 总份额=450
    /// - A 赎回 floor(750 * 200 / 450) = 333  => A 净 +133
    /// - C 赎回 floor(750 * 250 / 450) = 416  => C 净 +166
    function test_uma_case002_threeUsers_yesWins_closedLoop() external {
        (
            UnifiedMarket market,
            MinimalConditionalTokens ct,
            MockERC20 usdc,
            IOptimisticOracleV2 oov2
        ) = _contracts();
        market;

        usdc.mint(A, 200 * USDC_DECIMALS);
        usdc.mint(B, 300 * USDC_DECIMALS);
        usdc.mint(C, 250 * USDC_DECIMALS);
        _approve(usdc, A, address(ct));
        _approve(usdc, B, address(ct));
        _approve(usdc, C, address(ct));

        bytes32 q = _q(bytes32("case002"), address(ct));
        bytes32 conditionId = _prepare(ct, q);

        uint256 beforeA = usdc.balanceOf(A);
        uint256 beforeB = usdc.balanceOf(B);
        uint256 beforeC = usdc.balanceOf(C);

        _splitYes(ct, usdc, conditionId, A, 200 * USDC_DECIMALS);
        vm.warp(block.timestamp + 30);
        _splitNo(ct, usdc, conditionId, B, 300 * USDC_DECIMALS);
        vm.warp(block.timestamp + 30);
        _splitYes(ct, usdc, conditionId, C, 250 * USDC_DECIMALS);

        int256 resolved = _umaResolvePrice(oov2, WETH_SEPOLIA, MM, MM, 1);
        assertEq(resolved, 1, "UMA resolved price should be 1");
        _bridgeToCt(ct, q, true);

        _redeemYes(ct, usdc, conditionId, A);
        _redeemNo(ct, usdc, conditionId, B);
        _redeemYes(ct, usdc, conditionId, C);

        uint256 afterA = usdc.balanceOf(A);
        uint256 afterB = usdc.balanceOf(B);
        uint256 afterC = usdc.balanceOf(C);

        // expected payouts with floor division
        uint256 pool = 750 * USDC_DECIMALS;
        uint256 yesTotal = 450 * USDC_DECIMALS;
        uint256 expectedA = (pool * (200 * USDC_DECIMALS)) / yesTotal;
        uint256 expectedC = (pool * (250 * USDC_DECIMALS)) / yesTotal;

        assertEq(
            afterA,
            beforeA - 200 * USDC_DECIMALS + expectedA,
            "case002: A redeem mismatch"
        );
        assertEq(
            afterB,
            beforeB - 300 * USDC_DECIMALS,
            "case002: B should lose"
        );
        assertEq(
            afterC,
            beforeC - 250 * USDC_DECIMALS + expectedC,
            "case002: C redeem mismatch"
        );

        // 说明：本仓库 MinimalConditionalTokens 的 redeem 公式是按份额比例分配：
        //   payout = floor(stake * collateralPool * numerator / (den * sideTotal))
        // 在 YES 胜（numerator=1, den=1）时：payout = floor(stake * pool / yesTotal)
        // 因此这个用例的精确值是：
        // - A: floor(200e6 * 750e6 / 450e6) = 333_333_333
        // - C: floor(250e6 * 750e6 / 450e6) = 416_666_666
        assertEq(expectedA, 333_333_333, "case002: expectedA mismatch");
        assertEq(expectedC, 416_666_666, "case002: expectedC mismatch");

        // 同时断言至少一方正收益（忽略 gas）
        assertGt(afterA, beforeA, "case002: A should profit");
        assertGt(afterC, beforeC, "case002: C should profit");
    }

    /// @notice 用例#003：包含 MM 的“完整头寸”场景（MM 也 split FULL），A/C 押 YES，B 押 NO；UMA 结算 YES 胜。
    ///
    /// 按文档：
    /// - MM:1000(full), A:200(yes), B:300(no), C:250(yes) -> 总池=1750
    /// - YES 总份额=1450(MM1000 + A200 + C250)
    /// - A 赎回 floor(1750*200/1450) = 241 => A 净 +41
    /// - C 赎回 floor(1750*250/1450) = 301 => C 净 +51
    /// - MM 赎回 floor(1750*1000/1450)=1206 => MM 净 +206
    function test_uma_case003_withMM_yesWins_closedLoop() external {
        (
            UnifiedMarket market,
            MinimalConditionalTokens ct,
            MockERC20 usdc,
            IOptimisticOracleV2 oov2
        ) = _contracts();
        market;

        usdc.mint(MM, 1000 * USDC_DECIMALS);
        usdc.mint(A, 200 * USDC_DECIMALS);
        usdc.mint(B, 300 * USDC_DECIMALS);
        usdc.mint(C, 250 * USDC_DECIMALS);
        _approve(usdc, MM, address(ct));
        _approve(usdc, A, address(ct));
        _approve(usdc, B, address(ct));
        _approve(usdc, C, address(ct));

        bytes32 q = _q(bytes32("case003"), address(ct));
        bytes32 conditionId = _prepare(ct, q);

        uint256 beforeMM = usdc.balanceOf(MM);
        uint256 beforeA = usdc.balanceOf(A);
        uint256 beforeB = usdc.balanceOf(B);
        uint256 beforeC = usdc.balanceOf(C);

        // MM 提供完整头寸（YES+NO）
        vm.prank(MM);
        ct.splitPosition2(
            usdc,
            bytes32(0),
            conditionId,
            MinimalConditionalTokens.SplitKind.FULL,
            1000 * USDC_DECIMALS
        );

        vm.warp(block.timestamp + 30);
        _splitYes(ct, usdc, conditionId, A, 200 * USDC_DECIMALS);
        vm.warp(block.timestamp + 30);
        _splitNo(ct, usdc, conditionId, B, 300 * USDC_DECIMALS);
        vm.warp(block.timestamp + 30);
        _splitYes(ct, usdc, conditionId, C, 250 * USDC_DECIMALS);

        int256 resolved = _umaResolvePrice(oov2, WETH_SEPOLIA, MM, MM, 1);
        assertEq(resolved, 1, "UMA resolved price should be 1");
        _bridgeToCt(ct, q, true);

        _redeemYes(ct, usdc, conditionId, A);
        _redeemNo(ct, usdc, conditionId, B);
        _redeemYes(ct, usdc, conditionId, C);
        _redeemYes(ct, usdc, conditionId, MM);

        uint256 pool = 1750 * USDC_DECIMALS;
        uint256 yesTotal = 1450 * USDC_DECIMALS;
        uint256 expectedA = (pool * (200 * USDC_DECIMALS)) / yesTotal;
        uint256 expectedC = (pool * (250 * USDC_DECIMALS)) / yesTotal;
        uint256 expectedMM = (pool * (1000 * USDC_DECIMALS)) / yesTotal;

        _assertFinalBalance(
            usdc,
            A,
            beforeA,
            200 * USDC_DECIMALS,
            expectedA,
            "case003: A redeem mismatch"
        );
        assertEq(
            usdc.balanceOf(B),
            beforeB - 300 * USDC_DECIMALS,
            "case003: B should lose"
        );
        _assertFinalBalance(
            usdc,
            C,
            beforeC,
            250 * USDC_DECIMALS,
            expectedC,
            "case003: C redeem mismatch"
        );
        _assertFinalBalance(
            usdc,
            MM,
            beforeMM,
            1000 * USDC_DECIMALS,
            expectedMM,
            "case003: MM redeem mismatch"
        );

        // 精确值（按 MinimalConditionalTokens 的比例分配 + floor）：
        // - A: floor(200e6 * 1750e6 / 1450e6) = 241_379_310
        // - C: floor(250e6 * 1750e6 / 1450e6) = 301_724_137
        // - MM: floor(1000e6 * 1750e6 / 1450e6) = 1_206_896_551
        assertEq(expectedA, 241_379_310, "case003: expectedA mismatch");
        assertEq(expectedC, 301_724_137, "case003: expectedC mismatch");
        assertEq(expectedMM, 1_206_896_551, "case003: expectedMM mismatch");

        // 正收益断言（忽略 gas）：A、C 必须都是正收益
        assertGt(usdc.balanceOf(A), beforeA, "case003: A should profit");
        assertGt(usdc.balanceOf(C), beforeC, "case003: C should profit");
    }
}
