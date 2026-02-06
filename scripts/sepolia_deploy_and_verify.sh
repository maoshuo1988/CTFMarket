#!/usr/bin/env bash
set -euo pipefail

# Sepolia 一键脚本：
# 1) 从项目根目录读取 .env（RPC_URL / PRIVATE_KEY / UNIFIED_MARKET 等）
# 2) 先执行 Foundry script 的“模拟运行”（不 --broadcast，不会发交易）
# 3) 可选执行广播部署（BROADCAST=1 时开启，会真实发交易）
# 4) 对已部署的 UNIFIED_MARKET 执行只读校验（读链上配置，不发交易）
#
# 依赖：
# - forge / cast
# - .env 中 PRIVATE_KEY 必须是 0x 前缀的 32 字节 hex（否则 vm.envUint/--private-key 会解析失败）
#
# 安全提示：
# - 不要把真实私钥提交到 git
# - 本脚本会把 PRIVATE_KEY 通过参数传给 forge（注意你的 shell history / CI 日志）
#
# 幂等性：
# - “模拟运行”每次都会显示不同的预测地址（正常现象）
# - “广播部署”每次都会新部署一套合约（会增加 nonce，并消耗 Sepolia ETH）

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "[error] .env not found in repo root: $ROOT_DIR" >&2
  exit 1
fi

# 载入 .env 到当前 shell，使得 $RPC_URL / $PRIVATE_KEY / $UNIFIED_MARKET 可用
# set -a 会把 source 的变量自动 export，方便子进程（forge）读取
set -a
# shellcheck disable=SC1091
source .env
set +a

if [[ -z "${RPC_URL:-}" ]]; then
  echo "[error] RPC_URL is empty. Set it in .env" >&2
  exit 1
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "[error] PRIVATE_KEY is empty. Set it in .env" >&2
  exit 1
fi

# PRIVATE_KEY 应该是 0x 前缀 hex（vm.envUint + forge --private-key 都用这个格式）
if [[ "${PRIVATE_KEY}" != 0x* ]]; then
  echo "[error] PRIVATE_KEY must start with 0x" >&2
  exit 1
fi

echo "[info] RPC_URL=$RPC_URL"

# 第一步：只做模拟（不广播）
# - 会做链上模拟/估算 gas
# - 不会发交易，不消耗 ETH
echo "[step] 1/3 simulate deployment (no broadcast)"
forge script script/SepoliaDeployUnifiedMarket.s.sol:SepoliaDeployUnifiedMarket \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  -vvv

# 第二步：可选广播
# - BROADCAST=1 时才会执行 --broadcast
# - 广播会真实发交易并消耗 Sepolia ETH
echo "[step] 2/3 broadcast deployment (set BROADCAST=1 to enable)"
if [[ "${BROADCAST:-0}" == "1" ]]; then
  forge script script/SepoliaDeployUnifiedMarket.s.sol:SepoliaDeployUnifiedMarket \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    -vvv
else
  echo "[skip] BROADCAST != 1, skipping onchain broadcast"
fi

# 第三步：只读校验（读链上配置，不发交易）
# 需要 .env 中提供 UNIFIED_MARKET=0x...
echo "[step] 3/3 verify existing deployment (requires UNIFIED_MARKET in .env)"
if [[ -z "${UNIFIED_MARKET:-}" ]]; then
  echo "[warn] UNIFIED_MARKET is empty. Set it in .env to run verify." >&2
  exit 0
fi

forge script script/SepoliaVerifyUnifiedMarket.s.sol:SepoliaVerifyUnifiedMarket \
  --rpc-url "$RPC_URL" \
  -vvv

echo "[done]"
