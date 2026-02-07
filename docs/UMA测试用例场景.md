# UMA + ConditionalTokens 套利测试用例场景（Sepolia）

> 目标：设计一组**用户套利**测试用例，在 **Sepolia** 上结合 **UMA Optimistic Oracle V2** 完成“提出断言 → 结算 → 写入 ConditionalTokens payout → 赎回”的闭环。
>
> 约束（按需求逐条落实）：
>
> - 所有用例使用**相同的合约环境**与**统一的用户地址角色**（A/B/C/做市商）。
> - 只用最基本的合约行为描述用户动作：
>   - ERC20：`mint / approve / transferFrom`（若合约内部使用）
>   - ConditionalTokens：`prepareCondition / splitPosition / reportPayouts / redeemPositions`
>   - UMA OOV2：`assertTruth / settleAssertion`（或等价 API；以 Sepolia 上实际部署的 OOV2 为准）
> - **明确每个行为的次数与时间点**（T0/T+...）。
> - 不描述任何“非合约行为”（例如看新闻、超预期）。
> - 不使用 `CTFExchange`/`UnifiedMarket` 的方法（用例只围绕 ERC20 + ConditionalTokens + UMA）。
> - 假设稳定币最开始都是 0：从“构造代币/铸币”开始。
> - 用户 A/B/C 之间**不能互相交易**（无 ERC20/头寸 token 的互转；仅与合约交互）。
> - 每组用例：**至少一个用户稳定币正向收入**，且稳定币获利金额必须明确。
> - Gas 不纳入稳定币余额核算。

---

## 1. 通用合约环境（所有用例共用）

### 1.1 参与地址（固定角色）
- 做市商：`MM`
- 用户A：`A`
- 用户B：`B`
- 用户C：`C`

> 地址可以在脚本/测试中固定为：
> - `MM = address(0xMM)`（示意）
> - `A = address(0xA)`
> - `B = address(0xB)`
> - `C = address(0xC)`
>
> 要求：用例中只写“角色名”，不写实现细节。

### 1.2 部署合约（只做一次）
本环境在 Sepolia 上部署（建议由脚本完成），得到以下合约地址：

- 稳定币（MockUSDC，ERC20）：`USDC`
- 条件合约（ConditionalTokens，ERC1155）：`CT`
- UMA Optimistic Oracle V2：`OOV2`（Sepolia 上已部署地址）

**部署序列（只执行 1 次）：**

- T0：部署 `USDC`
- T0：部署 `CT`（构造参数：`oracle = OOV2`）

> 注意：这里的 `CT` 建议使用“MinimalConditionalTokens”这类可在 Sepolia 自洽运行的实现：
> - `prepareCondition(oracle, questionId, 2)`
> - `splitPosition(USDC, 0x0, conditionId, partition, amount)`
> - `reportPayouts(questionId, [pYes,pNo])`（要求 msg.sender == oracle）
> - `redeemPositions(USDC, 0x0, conditionId, indexSets)`
>
> OOV2 是 oracle 地址，因此 `reportPayouts` 需要通过“桥接器”完成（见 1.4）。

### 1.3 固定市场参数（所有用例一致）
- `outcomeSlotCount = 2`
- `YES indexSet = 1`
- `NO  indexSet = 2`
- `questionId = Q1`（统一问题 ID；如 `keccak256("UMA-ARBITRAGE-Q1")`）
- `conditionId = getConditionId(OOV2, Q1, 2)`

**准备条件（只执行 1 次）：**

- T0：`CT.prepareCondition(OOV2, Q1, 2)`（次数：1）

### 1.4 UMA → ConditionalTokens 的桥接约定（必须）
UMA 的结算结果不会自动写入 `CT`。

为满足“仅合约行为”约束，这里定义一个最小桥接过程（可用脚本实现，但行为仍然是合约调用）：

- 当 `OOV2.settleAssertion(assertionId)` 返回 `result` 后：
  - 若 `result == true`：设定 `payouts = [1,0]`
  - 若 `result == false`：设定 `payouts = [0,1]`
- 由 `OOV2` 地址触发（或由一个被 OOV2 调用的桥接合约触发）调用：
  - `CT.reportPayouts(Q1, payouts)`（次数：每个用例 1 次）

> 说明：
> - 在 Foundry fork 测试里，你可以用 `vm.prank(OOV2)` 来模拟“由 OOV2 发起 reportPayouts”。
> - 在真实 Sepolia 上，如果没有 OOV2 主动回调机制，需要一个 onchain 桥接合约或你控制的 oracle 地址。
> - 本文用例只要求“合约调用序列”，不规定桥接的实现方式。

### 1.5 禁止用户间交易
所有用例中禁止以下行为：
- A/B/C/MM 之间的 `USDC.transfer`
- A/B/C/MM 之间的 `CT.safeTransferFrom`（ERC1155 头寸转移）

所有资金流只能来自：
- 用户向 `CT` 抵押 `USDC`（splitPosition 内部 transferFrom）
- `CT` 赎回时向用户转回 `USDC`

---

## 2. 用例 #001：A 正确，B 错误（A 获利 +400 USDC）

> 目标：满足“至少一个用户正向收入且金额明确”。

### 初始铸币（所有余额从 0 开始）
- T0：`USDC.mint(A, 600)`（1 次）
- T0：`USDC.mint(B, 400)`（1 次）

### 授权
- T0：A 调用 `USDC.approve(CT, 600)`（1 次）
- T0：B 调用 `USDC.approve(CT, 400)`（1 次）

### 创建头寸
- T0：A 调用 `CT.splitPosition(USDC, 0x0, conditionId, [YES], 600)`（1 次）
- T0+30s：B 调用 `CT.splitPosition(USDC, 0x0, conditionId, [NO], 400)`（1 次）

### UMA 断言与结算（YES 胜）
- T0+60s：Proposer 调用 `OOV2.assertTruth(...)`（1 次）→ 得到 `assertionId`
- T0+L：任意人调用 `OOV2.settleAssertion(assertionId)`（1 次）→ `result=true`

### 写入 payout 与赎回
- T0+L+5s：调用 `CT.reportPayouts(Q1, [1,0])`（1 次）
- T0+L+10s：A 调用 `CT.redeemPositions(USDC, 0x0, conditionId, [YES])`（1 次）
- T0+L+10s：B 调用 `CT.redeemPositions(USDC, 0x0, conditionId, [NO])`（1 次）

### 期望资金流（忽略 gas）
- 总抵押池 = 600 + 400 = 1000
- YES 胜：YES 侧拿走全部 1000

**最终余额：**
- A：初始 600 → 最终 1000 → **净收益 +400 USDC**
- B：初始 400 → 最终 0 → 净收益 -400 USDC

---

## 3. 用例 #002：三方对赌，A/C 押 YES，B 押 NO（A 获利 +133，C 获利 +166）

### 初始铸币（从 0 开始）
- T0：`USDC.mint(A, 200)`（1 次）
- T0：`USDC.mint(B, 300)`（1 次）
- T0：`USDC.mint(C, 250)`（1 次）

### 授权
- T0：A 调用 `USDC.approve(CT, 200)`（1 次）
- T0：B 调用 `USDC.approve(CT, 300)`（1 次）
- T0：C 调用 `USDC.approve(CT, 250)`（1 次）

### 创建头寸
- T0：A 调用 `CT.splitPosition(USDC, 0x0, conditionId, [YES], 200)`（1 次）
- T0+30s：B 调用 `CT.splitPosition(USDC, 0x0, conditionId, [NO], 300)`（1 次）
- T0+60s：C 调用 `CT.splitPosition(USDC, 0x0, conditionId, [YES], 250)`（1 次）

### UMA 断言与结算（YES 胜）
- T0+90s：Proposer 调用 `OOV2.assertTruth(...)`（1 次）→ `assertionId`
- T0+L：任意人调用 `OOV2.settleAssertion(assertionId)`（1 次）→ `result=true`

### 写入 payout 与赎回
- T0+L+5s：调用 `CT.reportPayouts(Q1, [1,0])`（1 次）
- T0+L+10s：A 调用 `CT.redeemPositions(..., [YES])`（1 次）
- T0+L+10s：B 调用 `CT.redeemPositions(..., [NO])`（1 次）
- T0+L+10s：C 调用 `CT.redeemPositions(..., [YES])`（1 次）

### 期望资金流（忽略 gas，且整数除法向下取整）
- 总抵押池 = 200 + 300 + 250 = 750
- YES 总份额 = 200 + 250 = 450

赎回：
- A 赎回 = `floor(750 * 200 / 450) = floor(333.333...) = 333`
- C 赎回 = `floor(750 * 250 / 450) = floor(416.666...) = 416`
- B 赎回 = 0

**最终余额：**
- A：初始 200 → 最终 333 → **净收益 +133 USDC**
- C：初始 250 → 最终 416 → **净收益 +166 USDC**
- B：初始 300 → 最终 0 → 净收益 -300 USDC

> 备注：如果你的 ConditionalTokens 实现对“余数”有特殊处理（例如最后赎回者吃掉余数），请将预期值按合约实现修正。

---

## 4. 用例 #003：做市商提供完整头寸，A/C 买 YES，B 买 NO（A/C 获利，MM 亏损可控）

> 目标：引入“做市商 MM”角色，但仍不允许用户间交易。
>
> 约束解释：
> - 这里的“做市商”只通过 `CT.splitPosition([YES+NO])` 提供初始头寸；
> - A/B/C 仍然只能通过 `CT.splitPosition` 自己铸造 YES/NO（不通过购买/转移）。
> - 因为禁止用户间交易，本用例的“做市”仅体现为 MM 也在抵押池里承担风险。

### 初始铸币（从 0 开始）
- T0：`USDC.mint(MM, 1000)`（1 次）
- T0：`USDC.mint(A, 200)`（1 次）
- T0：`USDC.mint(B, 300)`（1 次）
- T0：`USDC.mint(C, 250)`（1 次）

### 授权
- T0：MM 调用 `USDC.approve(CT, 1000)`（1 次）
- T0：A 调用 `USDC.approve(CT, 200)`（1 次）
- T0：B 调用 `USDC.approve(CT, 300)`（1 次）
- T0：C 调用 `USDC.approve(CT, 250)`（1 次）

### 创建头寸
- T0：MM 调用 `CT.splitPosition(USDC, 0x0, conditionId, [YES+NO], 1000)`（1 次）
  - 结果：MM 同时持有 1000 YES + 1000 NO（但禁止转给用户）
- T0+30s：A 调用 `CT.splitPosition(..., [YES], 200)`（1 次）
- T0+60s：B 调用 `CT.splitPosition(..., [NO], 300)`（1 次）
- T0+90s：C 调用 `CT.splitPosition(..., [YES], 250)`（1 次）

### UMA 断言与结算（YES 胜）
- T0+120s：Proposer 调用 `OOV2.assertTruth(...)`（1 次）
- T0+L：任意人调用 `OOV2.settleAssertion(assertionId)`（1 次）→ `result=true`

### 写入 payout 与赎回（YES 赢）
- T0+L+5s：调用 `CT.reportPayouts(Q1, [1,0])`（1 次）
- T0+L+10s：A 赎回 YES（1 次）
- T0+L+10s：B 赎回 NO（1 次）
- T0+L+10s：C 赎回 YES（1 次）
- T0+L+10s：MM 赎回 YES（1 次；MM 也持有 YES）

### 期望资金流（忽略 gas，整数向下取整）
- 总抵押池 = 1000 + 200 + 300 + 250 = 1750
- YES 总份额 = MM(1000) + A(200) + C(250) = 1450

赎回（YES 赢）：
- A 赎回 = `floor(1750 * 200 / 1450) = floor(241.379...) = 241` → **A 净收益 +41**
- C 赎回 = `floor(1750 * 250 / 1450) = floor(301.724...) = 301` → **C 净收益 +51**
- MM 赎回 = `floor(1750 * 1000 / 1450) = floor(1206.896...) = 1206` → MM 净收益 +206
- B 赎回 = 0 → B 净收益 -300

> 说明：这个用例里 MM 也会盈利（因为 YES 赢且 MM 持有大量 YES）。
> 如果你希望“做市商承担损失、用户套利获利”，可将 UMA 结果设为 NO 赢并让 MM 持更多 YES，A/C 持 NO：
> 但考虑到每组至少一个用户正收益，本用例选择 YES 赢且 A/C 明确正收益。

---

## 5. 执行与验收方式（建议）

### 5.1 Sepolia 实测（需要真实交互 UMA）
建议用脚本执行行为序列：
- 部署 USDC/CT（一次）
- 为每组用例：
  - mint/approve/split
  - UMA assertTruth/settle
  - reportPayouts
  - redeem

### 5.2 Sepolia fork 验收（强烈推荐）
用 fork 测试复现并断言最终 `USDC.balanceOf`，可以稳定验证：

- `result == true/false` 对应 payout
- 赎回金额与整数取整逻辑

> 断言必须按照你实现的 ConditionalTokens 赎回公式/余数处理方式写死。

---

## 6. 断言清单（每组必须验证）

对每个用例，至少验证：
- `USDC.balanceOf(A/B/C/MM)` 与“期望最终余额”一致
- `CT` 对应 condition 已 resolved（不可重复 report）
- 赎回后 winning 头寸余额为 0（或按实现为准）

---

## 7. 用例汇总（稳定币净收益必须明确）

| 用例 | 结果方 | A | B | C | MM |
|---|---|---:|---:|---:|---:|
| #001 A vs B（YES 赢） | YES | **+400** | -400 | 0 | 0 |
| #002 A/C vs B（YES 赢） | YES | **+133** | -300 | **+166** | 0 |
| #003 含 MM（YES 赢） | YES | **+41** | -300 | **+51** | +206 |

> 注：以上均忽略 gas，且默认整数除法向下取整。
