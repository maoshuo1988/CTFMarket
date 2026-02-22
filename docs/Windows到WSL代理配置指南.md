# Windows 到 WSL 代理配置指南（以 Blockscout Sepolia 为例）

本文用于解决以下典型场景：

- Windows 上已能通过代理访问外网（例如在浏览器里可打开 Blockscout）
- 项目在 WSL（Ubuntu 等）中运行（Foundry/forge/cast 脚本在 WSL 内执行）
- 但在 WSL 中用 `127.0.0.1:7897` 作为代理地址会失败

原因是：**WSL 里的 `127.0.0.1` 指向 WSL 自己，不是 Windows 宿主机**。因此需要把代理地址从 `127.0.0.1:PORT` 换成 **Windows 宿主机在 WSL 视角下的 IP:PORT**。

---

## 1）查看 Windows 浏览器/系统的代理配置

你需要确认两件事：

1. Windows 当前启用的代理类型（系统代理 / 代理软件）
2. 代理监听地址与端口（常见如 `127.0.0.1:7890/7897/10809` 等）

### 1.1 在 Windows 系统设置里查看（推荐）

打开：

- **设置** → **网络和 Internet** → **代理**

重点关注：

- “使用代理服务器”是否开启
- 代理地址（Address）与端口（Port）

你最终应得到一个代理地址，例如：

- `127.0.0.1:7897`

> 注：这通常是你的代理客户端（Clash / v2rayN / Surge / etc）在 Windows 本机的监听端口。

### 1.2 在代理客户端里确认（强烈建议）

不同客户端名称不同，但一定要确认：

- HTTP 代理端口（HTTP Proxy Port）
- 是否开启了“允许局域网连接 / Allow LAN”（非常关键，关系到 WSL 能否访问 Windows 的代理端口）

---

## 2）使用代理地址访问 Blockscout（Windows 侧验证）

目标：确认 **Windows 本机代理本身是可用的**。

### 2.1 浏览器验证（最简单）

在 Windows 浏览器直接访问：

- https://eth-sepolia.blockscout.com/

如可正常打开，说明 Windows 侧“代理 → 外网”链路大概率正常。

### 2.2 命令行验证（可选，更准确）

在 Windows PowerShell（或 Git Bash）里测试代理请求：

```bash
# 仅示例：端口按你的实际配置修改
curl -x http://127.0.0.1:7897 -I --max-time 8 https://eth-sepolia.blockscout.com/ | head
```

如果返回 `HTTP/2 200`/`HTTP/1.1 200`/`301` 等响应头，说明代理可用。

---

## 3）配置 WSL 中的代理地址（关键步骤）

### 3.1 为什么 WSL 不能用 127.0.0.1

在 WSL 中：

- `127.0.0.1` 是 **WSL 自己**
- Windows 代理客户端是跑在 **Windows 宿主机** 上

所以在 WSL 里访问 `http://127.0.0.1:7897`，通常会得到：

- Connection refused

### 3.2 获取 Windows 宿主机在 WSL 里的 IP

在 WSL 里运行：

```bash
ip route | awk '/default/ {print $3; exit}'
```

通常会输出类似：

- `172.27.48.1`

这个 IP 通常就是 **Windows 宿主机地址（WSL 视角下）**。

> 说明：不同机器/重启后该网段可能变化，这是正常的。

### 3.3 在 WSL 中用宿主机 IP 访问代理

假设：

- Windows 代理端口是 `7897`
- WSL 查到的 Windows IP 是 `172.27.48.1`

那么在 WSL 里应使用：

- `http://172.27.48.1:7897`

先验证通不通：

```bash
curl -x http://172.27.48.1:7897 -I --max-time 8 https://eth-sepolia.blockscout.com/ | head
```

如果仍然失败，通常是 Windows 代理客户端未开启 “Allow LAN/允许局域网连接”，或者 Windows 防火墙阻挡了该端口的入站访问。

### 3.4 在 WSL 中设置环境变量（通用）

你可以在当前终端临时设置：

```bash
export HTTP_PROXY=http://172.27.48.1:7897
export HTTPS_PROXY=http://172.27.48.1:7897
export ALL_PROXY=http://172.27.48.1:7897
```

或者写进 `~/.bashrc`（长期生效）：

```bash
echo 'export HTTP_PROXY=http://172.27.48.1:7897' >> ~/.bashrc
echo 'export HTTPS_PROXY=http://172.27.48.1:7897' >> ~/.bashrc
echo 'export ALL_PROXY=http://172.27.48.1:7897' >> ~/.bashrc
source ~/.bashrc
```

### 3.5 对 Foundry/Alchemy RPC 的建议：NO_PROXY

部分代理/网络环境下，RPC（例如 Alchemy）通过代理可能失败（CONNECT 被拒绝）。

建议在 WSL 中把 RPC 域名加入 `NO_PROXY`，让它直连：

```bash
export NO_PROXY=eth-sepolia.g.alchemy.com
export no_proxy=eth-sepolia.g.alchemy.com
```

如果你的 `RPC_URL` 换成了别的域名，把对应域名也加进去即可。

---

## 4）与本仓库脚本配合（可选）

本仓库 `scripts/sepolia_verify_contracts_from_env.sh` 支持用 `PROXY_URL` 传入代理地址：

```bash
# 示例：请按你实际的 Windows-IP 修改
PROXY_URL=http://172.27.48.1:7897 ./scripts/sepolia_verify_contracts_from_env.sh
```

这种方式优点是：

- 不需要改全局代理
- 只对当前脚本生效

---

## 常见问题排查

### Q1：WSL 里用宿主机 IP 还是连不上代理？

优先检查 Windows 侧：

- 代理客户端是否开启 “Allow LAN/允许局域网连接”
- 防火墙是否允许代理端口入站
- 代理客户端监听地址是否为 `127.0.0.1`（只监听本机）还是 `0.0.0.0`（允许局域网）

### Q2：Blockscout 能访问，但 forge verify 还失败？

`forge verify-contract` 可能还需要访问：

- `https://binaries.soliditylang.org/`（下载 solc 列表/编译器）

请用同样的代理在 WSL 里测试：

```bash
curl -x http://172.27.48.1:7897 -I --max-time 8 https://binaries.soliditylang.org/bin/list.txt | head
```

只要这个通了，verify 的“下载 solc”阶段通常就不会再卡在网络上。
