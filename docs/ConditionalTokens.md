# Conditional Tokens（CT）整体模型

本项目使用（或兼容）Gnosis Conditional Tokens 的核心思想：

- **Condition（条件）**：一个待裁决的事件。由 `(oracle, questionId, outcomeSlotCount)` 唯一确定。
- **oracle（裁决源）**：最终有权把结果写入 CT 的地址。
    - 在本项目里通常是 **UMA Optimistic Oracle**（或由市场合约充当适配器再转写）。
- **questionId（问题 ID）**：`bytes32`，业务上代表“是哪一个问题/市场”。
- **outcomeSlotCount（结果槽数量）**：该条件有多少个互斥结果。二元市场为 `2`（YES/NO）。
- **payoutNumerators（赔付分子数组）**：条件解析时上报的数组，长度必须等于 `outcomeSlotCount`。
    - **分母**为 `payoutDenominator = sum(payoutNumerators)`。
    - 对某个结果槽 `i`，兑付比例 = `payoutNumerators[i] / payoutDenominator`。

## Gnosis Conditional Tokens
[源代码仓](https://github.com/gnosis/conditional-tokens-contracts/tree/master)
---

## 参数与业务含义

在 CT/市场合约里会反复遇到的 **参数** 解释清楚；理解这些参数，就能理解 prepare/split/report/redeem 等所有流程。

### `oracle`（裁决源）

- **它是什么**：最终“写入解析结果的人/合约”的地址。
- **业务含义**：
    - 它决定“这个市场最终谁说了算”。
    - 市场结束时，只有 `oracle` 才能把结果上链并使市场进入可兑付状态。
- **在本项目中**：通常是 UMA Optimistic Oracle（或由你的 MarketCreator 合约做一层适配后再转写）。

### `questionId`（问题/市场唯一 ID）

- **它是什么**：一个 `bytes32` 的唯一标识。
- **业务含义**：
    - 它把“链上可结算的条件”与“链下展示的问题文本/规则/截止时间”等元数据绑定在一起。
    - 前端/索引器通常会用 `questionId` 查回完整市场信息。
- **实践建议**：把问题文本、创建者、时间戳、chainid 等混合哈希，避免重复创建同题市场。

### `outcomeSlotCount`（结果数量）

- **它是什么**：这个市场有几个互斥结果。
- **业务含义**：
    - 二元市场就是 2 个结果（YES 与 NO）。
    - 若你未来做多选题（A/B/C/D），则为 4。
- **注意**：结果越多，头寸类型越多，前端展示与交易路由也更复杂。

### `conditionId`（条件 ID）

- **它是什么**：由 `(oracle, questionId, outcomeSlotCount)` 计算出的唯一 ID。
- **业务含义**：
    - CT 合约内部用它索引该市场的状态（是否已解析、解析比例等）。
    - 你可以把它理解成“链上的市场主键”。

### `collateralToken`（抵押品）

- **它是什么**：用来计价、托管、最终兑付的 ERC20（如 USDC）。
- **业务含义**：
    - 用户买入/卖出的结果头寸，最终都会以该抵押品结算。
    - 同一个问题如果换抵押品（USDC vs DAI），在 CT 体系里会对应不同的头寸体系（不能互相兑付）。

### `amount`（拆分/投入的数量）

- **它是什么**：用户希望投入/拆分成头寸的抵押品数量。
- **业务含义**：
    - 可理解为用户为“铸造一套结果头寸”所投入的本金。
    - 在二元市场最直观的理解：投入 `amount` 的抵押品，会同时获得 YES 头寸与 NO 头寸各一份“可结算权利”。

### `payouts` / `payoutNumerators`（兑付比例：分子数组）

- **它是什么**：市场结束后上报的一个数组，长度等于 `outcomeSlotCount`。
- **业务含义**：
    - 它决定每个结果头寸最后能换回多少抵押品。
    - 兑付比不是“0/1 二选一”——也支持平局/部分有效/多结果分摊。
- **如何理解（不用关心精度）**：
    - 设 `payouts = [a, b]`，那么 YES 得到 `a/(a+b)` 的兑付比例，NO 得到 `b/(a+b)`。
    - 二元市场常见：YES 赢 `[0, 1]`（或 `[0, 1e6]`），NO 赢 `[1, 0]`。

### `indexSet` / `indexSets`（结果选择集合）

- **它是什么**：用“位图”表示你选中了哪些结果。
- **业务含义**：
    - 它是“头寸归属哪个结果/哪个结果组合”的标签。
    - 对二元市场：
        - `1` 表示第 0 个结果（例如 NO）
        - `2` 表示第 1 个结果（例如 YES）
    - 你可以把它理解成一个“选项编号”，只是底层用位图更容易做组合题。

---

## `partition`（拆分方案）——纯业务解释（重点）

`partition` 是 Conditional Tokens 里一个非常关键但也最容易困惑的参数。

- **它是什么**：一次“拆分/合并”操作中，你准备把一笔本金（或一个较大的头寸）分成哪些“互斥的结果包”。

- **它回答的问题**：
    - “我这次要把一笔钱，拆成哪几种结果的持仓？”
    - “这些结果之间是否互相重叠？是否覆盖了我想覆盖的范围？”

- **核心业务规则**（把它当成金融产品条款来理解）：
    1. **互斥**：`partition` 里的每个“结果包”彼此不能重复覆盖同一个结果。
         - 业务含义：你不能同时把“YES”既放进 A 包又放进 B 包，否则相当于“一份本金重复发行了两次权利”。
    2. **同一底仓的切片**：它们应该来自同一个“底仓范围”。
         - 业务含义：你是在对同一份本金做切割，而不是凭空多出或少掉某个结果的权利。
    3. **覆盖范围要清晰**：
         - 二元市场最常见的拆分就是把“全覆盖”拆成两个互斥结果：YES 与 NO。
         - 这样做的业务意义是：你买了这套切片后，无论结果走向如何，总有人能拿这份本金的兑付（只是最终分给哪一片取决于裁决）。

- **用“保险/对赌”来类比（最直观）**：
    - 你投入 100 USDC，发行两张“票据”：
        - 票据 A：事件发生时能兑付（例如 YES）
        - 票据 B：事件不发生时能兑付（例如 NO）
    - `partition` 就是在定义“这次我要发行哪些票据组合”。
    - 对二元市场，最标准的就是发行 A 与 B 两张票据，它们互斥且覆盖全部结果。

- **二元市场的业务含义**：
    - 当 `partition` 设置为“YES + NO”时：
        - 你投入的本金被铸造成两种相反方向的权利。
        - 市场交易本质上是这两种权利在不同价格下流通。
        - 结算时，胜出的那张票据能按 100% 比例兑付，另一张兑付为 0（或按平局规则分摊）。

---

---

## Collection / Position 的 ID 计算（用于前端展示/对齐标准 CT）

虽然本仓库最小实现不完整实现 ERC1155 的 positionId，但接口仍提供了与标准 CT 对齐的计算方法，便于未来替换为完整的 Gnosis ConditionalTokens。

### 1) `getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet) -> bytes32`

- **用途**：计算某个“结果集合”的 `collectionId`。
- **参数**
    - `parentCollectionId`：父集合；常用 `bytes32(0)`。
    - `conditionId`：条件 ID。
    - `indexSet`：位图，表示选了哪些结果槽。
- **二元市场的 indexSet 约定**
    - `1` 表示第 0 个 outcome（二进制 `01`）
    - `2` 表示第 1 个 outcome（二进制 `10`）

### 2) `getPositionId(IERC20 collateralToken, bytes32 collectionId) -> uint256`

- **用途**：计算某个头寸的 tokenId（标准 CT 中是 ERC1155 tokenId）。
- **业务含义**：`collateralToken + collectionId` 唯一确定一种头寸。

---

## 二元市场（YES/NO）在本仓库的推荐参数约定

- `outcomeSlotCount = 2`
- `partition = [1, 2]`（或 `[2,1]`，但全项目要一致）
- `payouts` 推荐使用统一精度（例如 1e6）：
    - YES 赢：`[0, 1e6]`
    - NO 赢：`[1e6, 0]`

---