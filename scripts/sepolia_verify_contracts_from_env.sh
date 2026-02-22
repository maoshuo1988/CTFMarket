#!/usr/bin/env bash
set -euo pipefail

now_ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(now_ts)] $*"; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE="$ROOT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  ENV_FILE="$ROOT_DIR/../.env"
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "[error] 找不到 .env。已尝试：$ROOT_DIR/.env 和 $ROOT_DIR/../.env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$ENV_FILE"
set +a

if [[ -z "${RPC_URL:-}" ]]; then
  echo "[error] RPC_URL 为空，请在 .env 中配置" >&2
  exit 1
fi
if [[ -z "${BLOCKSCOUT_SEPOLIA_API_URL:-}" ]]; then
  echo "[error] BLOCKSCOUT_SEPOLIA_API_URL 为空，请在 .env 中配置" >&2
  exit 1
fi

# 验证器选择：
# - VERIFIER=blockscout：使用 Blockscout，需要 BLOCKSCOUT_SEPOLIA_API_URL
# - VERIFIER=etherscan（默认）：使用 Etherscan，需要 ETHERSCAN_API_KEY（或 ETHERSCAN_SEPOLIA_API_KEY）
VERIFIER="${VERIFIER:-etherscan}"
if [[ "$VERIFIER" != "blockscout" && "$VERIFIER" != "etherscan" ]]; then
  echo "[error] VERIFIER 仅支持 blockscout 或 etherscan，当前=$VERIFIER" >&2
  exit 1
fi

log "workspace=$ROOT_DIR"
log "env_file=$ENV_FILE"
log "rpc_url=$RPC_URL"
log "verifier=$VERIFIER"
log "blockscout_api_url=$BLOCKSCOUT_SEPOLIA_API_URL"
log "提示：本脚本会访问 Blockscout API。如果网络受限，请设置 HTTPS_PROXY/HTTP_PROXY。"
log "网络：Sepolia (chainId=11155111)"

# 可选：一键代理（方便命令行传参，不改全局环境）
# 用法：PROXY_URL=http://127.0.0.1:7897 ./scripts/sepolia_verify_contracts_from_env.sh
if [[ -n "${PROXY_URL:-}" ]]; then
  export HTTP_PROXY="$PROXY_URL"
  export HTTPS_PROXY="$PROXY_URL"
  log "已启用代理：$PROXY_URL"
fi

# 识别“当前实际生效的代理”（优先 HTTPS_PROXY，其次 HTTP_PROXY/ALL_PROXY）
effective_proxy="${HTTPS_PROXY:-${HTTP_PROXY:-${ALL_PROXY:-}}}"
if [[ -n "${effective_proxy:-}" && -z "${PROXY_URL:-}" ]]; then
  log "检测到环境已设置代理（未通过 PROXY_URL 显式传入）"
  log "effective_proxy=$effective_proxy"
fi

# 快速自检：如果配置的是本地代理 127.0.0.1:7897，但代理服务没开，会出现 Connection refused
if [[ -n "${effective_proxy:-}" && "${effective_proxy}" == *"127.0.0.1:7897"* ]]; then
  if command -v curl >/dev/null 2>&1; then
    if ! curl -sS -I --max-time 2 http://127.0.0.1:7897 >/dev/null 2>&1; then
      log "警告：检测到代理指向 127.0.0.1:7897，但本地端口不可用（代理可能未启动）。"
      log "这会导致访问 Blockscout/solc binaries 等外网资源直接失败。"
    fi
  fi
fi

# 重要：如果设置了代理，某些本地代理对 HTTPS CONNECT（尤其是 Alchemy 这类 RPC 域名）可能会拒绝，
# 会导致 cast/forge 访问 RPC_URL 失败。
# Blockscout 需要走代理，但 RPC_URL 通常不需要。
# 因此：检测到代理时，自动把 RPC_URL 的主机加入 NO_PROXY/no_proxy，保证 RPC 直连。
proxy_enabled=0
if [[ -n "${HTTPS_PROXY:-}" || -n "${HTTP_PROXY:-}" || -n "${ALL_PROXY:-}" ]]; then
  proxy_enabled=1
fi

rpc_host=""
if command -v python3 >/dev/null 2>&1; then
  rpc_host="$(python3 - <<'PY'
import os
from urllib.parse import urlparse
u = os.environ.get('RPC_URL','')
try:
  print(urlparse(u).hostname or '')
except Exception:
  print('')
PY
)"
fi

if [[ "$proxy_enabled" == "1" && -n "$rpc_host" ]]; then
  export NO_PROXY="${NO_PROXY:-}${NO_PROXY:+,}$rpc_host"
  export no_proxy="${no_proxy:-}${no_proxy:+,}$rpc_host"
  log "已为 RPC 主机自动设置 NO_PROXY：$rpc_host"
fi

# 运行前校验：确认 RPC 指向 Sepolia，避免验证到错误网络。
CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL" 2>&1)" || {
  echo "[error] 无法从 RPC_URL 获取 chainId，请检查 RPC_URL/网络连接。" >&2
  exit 1
}
CHAIN_ID="${CHAIN_ID//$'\r'/}"
CHAIN_ID="${CHAIN_ID//$'\n'/}"
if [[ -z "$CHAIN_ID" ]]; then
  echo "[error] 无法从 RPC_URL 获取 chainId（输出为空）。请检查 RPC_URL/网络连接。" >&2
  exit 1
fi
if [[ "$CHAIN_ID" != "11155111" ]]; then
  echo "[error] RPC_URL 对应的 chainId=$CHAIN_ID，非 Sepolia(11155111)。请检查 .env 的 RPC_URL" >&2
  exit 1
fi

# 轻量连通性提示（不强制失败）：让用户知道 Blockscout 域名是否可达。
if command -v curl >/dev/null 2>&1; then
  if ! curl -sS --max-time 5 "$BLOCKSCOUT_SEPOLIA_API_URL" >/dev/null 2>&1; then
    log "提示：当前环境访问 Blockscout API 可能超时（这会导致 verify 重试/等待）。如需代理请设置 HTTPS_PROXY/HTTP_PROXY。"
  fi
fi

# 期望的环境变量（本仓库约定的 key）：
# - UnifiedMarket
# - MinimalConditionalTokens
# - MockERC20

verify_contract() {
  local addr contract_path constructor_args
  addr="$1"
  contract_path="$2"
  constructor_args="${3:-}"

  if [[ -z "$addr" ]]; then
    log "跳过：$contract_path 地址为空"
    return 0
  fi

  log "开始验证：$contract_path @ $addr"

  # VERIFIER=blockscout：使用 Blockscout，并通过 --verifier-url 指定 API。
  # BLOCKSCOUT_SEPOLIA_API_URL 示例：https://eth-sepolia.blockscout.com/api/
  # VERIFIER=etherscan：使用 Etherscan（Sepolia），需要 API key。
  if [[ "$VERIFIER" == "blockscout" ]]; then
    if [[ -n "$constructor_args" ]]; then
      forge verify-contract \
        --chain sepolia \
        --verifier blockscout \
        --verifier-url "$BLOCKSCOUT_SEPOLIA_API_URL" \
        --watch \
        --constructor-args "$constructor_args" \
        "$addr" \
        "$contract_path"
    else
      forge verify-contract \
        --chain sepolia \
        --verifier blockscout \
        --verifier-url "$BLOCKSCOUT_SEPOLIA_API_URL" \
        --watch \
        "$addr" \
        "$contract_path"
    fi
  else
    # Etherscan key 约定：优先 ETHERSCAN_SEPOLIA_API_KEY，其次 ETHERSCAN_API_KEY
    local etherscan_key
    etherscan_key="${ETHERSCAN_SEPOLIA_API_KEY:-${ETHERSCAN_API_KEY:-}}"
    if [[ -z "$etherscan_key" ]]; then
      echo "[error] VERIFIER=etherscan 需要 ETHERSCAN_SEPOLIA_API_KEY 或 ETHERSCAN_API_KEY" >&2
      exit 1
    fi
    if [[ -n "$constructor_args" ]]; then
      forge verify-contract \
        --chain sepolia \
        --verifier etherscan \
        --etherscan-api-key "$etherscan_key" \
        --watch \
        --constructor-args "$constructor_args" \
        "$addr" \
        "$contract_path"
    else
      forge verify-contract \
        --chain sepolia \
        --verifier etherscan \
        --etherscan-api-key "$etherscan_key" \
        --watch \
        "$addr" \
        "$contract_path"
    fi
  fi
}

# ---- UnifiedMarket ----
# UnifiedMarket(address conditionalTokens, address collateralToken, address oracle)
if [[ -n "${UnifiedMarket:-}" ]]; then
  if [[ -z "${MinimalConditionalTokens:-}" || -z "${MockERC20:-}" ]]; then
    log "警告：环境变量缺少 MinimalConditionalTokens/MockERC20；无法可靠构造 UnifiedMarket 的构造参数。"
    log "提示：请在 .env 中配置 MinimalConditionalTokens=0x... 和 MockERC20=0x..."
  fi
fi

# 尽量在本地拼出 UnifiedMarket 的构造参数。
UM_ARGS=""
if [[ -n "${UnifiedMarket:-}" && -n "${MinimalConditionalTokens:-}" && -n "${MockERC20:-}" ]]; then
  # 本仓库的 Sepolia 部署流程中，Oracle 默认固定为 UMA OOV2（也可用 env 覆盖）。
  ORACLE_ADDR="${OPTIMISTIC_ORACLE_V2:-0x9f1263B8f0355673619168b5B8c0248f1d03e88C}"
  UM_ARGS="$(cast abi-encode "constructor(address,address,address)" "$MinimalConditionalTokens" "$MockERC20" "$ORACLE_ADDR")"
  log "UnifiedMarket 构造参数已编码（长度=${#UM_ARGS}）"
fi

if [[ -n "${UnifiedMarket:-}" ]]; then
  if [[ -n "$UM_ARGS" ]]; then
    log "验证 UnifiedMarket：src/exchange/UnifiedMarket.sol:UnifiedMarket @ $UnifiedMarket"
    verify_contract \
      "$UnifiedMarket" \
      "src/exchange/UnifiedMarket.sol:UnifiedMarket" \
      "$UM_ARGS"
  else
    log "跳过 UnifiedMarket 验证：缺少构造参数；请配置 MinimalConditionalTokens/MockERC20（以及可选 OPTIMISTIC_ORACLE_V2）"
  fi
else
  log "跳过 UnifiedMarket 验证：环境变量未设置 UnifiedMarket"
fi

# 可选：当我们已知构造参数时，一并验证依赖合约。
# MinimalConditionalTokens(address oracle)
if [[ -n "${MinimalConditionalTokens:-}" ]]; then
  ORACLE_ADDR="${OPTIMISTIC_ORACLE_V2:-0x9f1263B8f0355673619168b5B8c0248f1d03e88C}"
  CT_ARGS="$(cast abi-encode "constructor(address)" "$ORACLE_ADDR")"
  log "验证 MinimalConditionalTokens：src/exchange/MinimalConditionalTokens.sol:MinimalConditionalTokens @ $MinimalConditionalTokens"
  verify_contract \
    "$MinimalConditionalTokens" \
    "src/exchange/MinimalConditionalTokens.sol:MinimalConditionalTokens" \
    "$CT_ARGS"
else
  log "跳过 MinimalConditionalTokens 验证：环境变量未设置 MinimalConditionalTokens"
fi

# MockERC20(string name, string symbol)
if [[ -n "${MockERC20:-}" ]]; then
  # 默认参数与 SepoliaDeployUnifiedMarket 脚本一致。
  ERC_ARGS="$(cast abi-encode "constructor(string,string)" "Mock USDC" "mUSDC")"
  log "验证 MockERC20：src/exchange/MockERC20.sol:MockERC20 @ $MockERC20"
  verify_contract \
    "$MockERC20" \
    "src/exchange/MockERC20.sol:MockERC20" \
    "$ERC_ARGS"
else
  log "跳过 MockERC20 验证：环境变量未设置 MockERC20"
fi

log "完成"
