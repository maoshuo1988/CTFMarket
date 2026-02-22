#!/usr/bin/env bash
set -euo pipefail

# Sepolia 一键脚本：
# 1) 从项目根目录读取 .env（RPC_URL / PRIVATE_KEY / UnifiedMarket 等）
# 2) 先执行 Foundry script 的“模拟运行”（不 --broadcast，不会发交易）
# 3) 可选执行广播部署（BROADCAST=1 时开启，会真实发交易）
# 4) 对已部署的 UnifiedMarket 执行只读校验（读链上配置，不发交易）
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

now_ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(now_ts)] $*"; }

run_forge() {
  # Ensure line-buffered output and add timestamps for better observability.
  # shellcheck disable=SC2068
  stdbuf -oL -eL forge $@ 2>&1 | awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0; fflush(); }'
}

is_tty() {
  [[ -t 0 && -t 1 ]]
}

should_run_step() {
  local prompt default_answer ans
  prompt="$1"
  default_answer="${2:-Y}"

  # Non-interactive mode: don't prompt.
  if [[ "${INTERACTIVE:-1}" == "0" ]] || ! is_tty; then
    return 0
  fi

  while true; do
    read -r -p "$prompt [Y/n] " ans
    ans="${ans:-$default_answer}"
    case "$ans" in
      Y|y) return 0 ;;
      N|n) return 1 ;;
      *) echo "Please answer Y or N." ;;
    esac
  done
}
step_start() {
  STEP_NAME="$1"
  STEP_T0="$(date +%s)"
  log "==> START: $STEP_NAME"
}
step_end() {
  local t1
  t1="$(date +%s)"
  log "<== END:   $STEP_NAME (took $((t1 - STEP_T0))s)"
  echo
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE="$ROOT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  # Workspace may keep a single shared .env one level above (e.g. AlogeDesign/.env)
  ENV_FILE="$ROOT_DIR/../.env"
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[error] .env not found. Looked for: $ROOT_DIR/.env and $ROOT_DIR/../.env" >&2
  exit 1
fi

log "workspace=$ROOT_DIR"
log "env_file=$ENV_FILE"

# 载入 .env 到当前 shell，使得 $RPC_URL / $PRIVATE_KEY / $UNIFIED_MARKET 可用
# set -a 会把 source 的变量自动 export，方便子进程（forge）读取
set -a
# shellcheck disable=SC1091
source "$ENV_FILE"
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

PK_FINGERPRINT="${PRIVATE_KEY:0:6}...${PRIVATE_KEY: -4}"
log "rpc_url=$RPC_URL"
log "private_key=$PK_FINGERPRINT"

# 第一步：只做模拟（不广播）
# - 会做链上模拟/估算 gas
# - 不会发交易，不消耗 ETH
if should_run_step "Run step 1/3: simulate deployment (no broadcast)?" "Y"; then
  step_start "1/3 simulate deployment (no broadcast)"
  log "note: after compilation, Foundry will do RPC simulation/estimateGas; this can take 1-3 minutes on Sepolia (no output during the wait)."
  run_forge clean
  run_forge script script/SepoliaDeployUnifiedMarket.s.sol:SepoliaDeployUnifiedMarket \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    -vvv
  step_end
else
  log "skip: step 1/3"
  echo
fi

# 第二步：可选广播
# - BROADCAST=1 时才会执行 --broadcast
# - 广播会真实发交易并消耗 Sepolia ETH
if [[ "${BROADCAST:-0}" == "1" ]]; then
  if should_run_step "Run step 2/3: broadcast deployment to Sepolia (will spend ETH)?" "N"; then
    step_start "2/3 broadcast deployment"
    log "broadcast enabled: sending onchain txs (Sepolia ETH will be spent)"
    run_forge script script/SepoliaDeployUnifiedMarket.s.sol:SepoliaDeployUnifiedMarket \
      --rpc-url "$RPC_URL" \
      --private-key "$PRIVATE_KEY" \
      --broadcast \
      -vvv
    step_end
  else
    log "skip: step 2/3 (user chose NO)"
    echo
  fi
else
  log "skip: step 2/3 (BROADCAST != 1)"
  echo
fi

# 第三步：只读校验（读链上配置，不发交易）
# 需要 .env 中提供 UnifiedMarket=0x...
if should_run_step "Run step 3/3: read-only verify existing deployment?" "Y"; then
  step_start "3/3 read-only verify existing deployment (requires UnifiedMarket in env)"
  if [[ -z "${UnifiedMarket:-}" ]]; then
    log "warn: UnifiedMarket is empty. Set it in .env to run verify."
    exit 0
  fi

  log "verifying UnifiedMarket=$UnifiedMarket (read-only)"
  log "note: if this step appears to hang, it's usually waiting for RPC responses; keep it running."

  run_forge script script/SepoliaVerifyUnifiedMarket.s.sol:SepoliaVerifyUnifiedMarket \
    --rpc-url "$RPC_URL" \
    -vvv

  step_end
else
  log "skip: step 3/3"
  echo
fi

log "done"
