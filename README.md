# DoH Manager 🚀

> 专为存在 DNS 劫持、污染与 53 端口阻断的 Linux VPS 设计的轻量级 DNS-over-HTTPS (DoH) 一键部署与运维管理工具。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Linux](https://img.shields.io/badge/Platform-Linux-blue.svg)](https://www.kernel.org/)
[![Bash Shell](https://img.shields.io/badge/Language-Bash-green.svg)](https://www.gnu.org/software/bash/)

---

## 📖 项目背景

在部分 VPS 网络环境中，运营商或上游网络会对标准的 UDP 53 端口执行流量拦截、DNS 污染或直接封锁，导致机器出现域名解析超时、系统源更新失败，甚至部分海外服务彻底失联。

**DoH Manager** 通过在本地启动极低资源占用的 DoH 转发客户端，将系统发起的 DNS 请求封装为标准的 HTTPS 加密流量（443 端口）发往上游公共 DoH 节点，彻底绕过 53 端口封锁与中间人劫持。

---

## ✨ 核心特性

- **极低内存占用**：支持基于 Go 的轻量级核心（`dnsproxy` 约 10MB，`cloudflared` 约 25MB），对小内存 VPS 零负担。
- **并发双节点竞速**：支持自定义选择 2 个上游节点（如 Cloudflare + Google 并行查询），毫秒级择优返回。
- **内置 Bootstrap 防死锁**：自动在 `/etc/hosts` 注入常用 DoH 域名静态解析，彻底解决因解析域名引发的依赖死锁。
- **集成 13 大主流节点**：预置 Google、Cloudflare、Quad9、Cisco/OpenDNS、Umbrella、Cisco SSE 等纯 IP 与官方域名端点。
- **全自动诊断与测速**：
  - **13 节点跑分**：批量探测各上游的 TCP 握手耗时、TLS 握手耗时与总响应延迟（TTFB）。
  - **连通性体检**：自动验证本地 127.0.0.1:53 监听、实际域名解析及全局外网连通状态。
- **多架构自适应**：智能识别 `x86_64 / amd64`、`aarch64 / arm64` 等主流 Linux 架构。

---

## ⚡ 一键安装与运行

在 Linux VPS 终端执行以下命令（需 `root` 权限）：

```bash
curl -fsSL https://raw.githubusercontent.com/fxxkmkd/doh_manager/main/doh_manager.sh -o doh_manager.sh && chmod +x doh_manager.sh && ./doh_manager.sh
```

---

## 🛠️ 主菜单预览

```text
=======================================================
          低内存 DoH 客户端集成部署管理脚本          
=======================================================
 1. 部署 dnsproxy    [最推荐 / 内存~10MB / 并发竞速模式]
 2. 部署 cloudflared [官方客户端 / 内存~25MB / 稳定直链已锁版]
 -----------------------------------------------------
 3. 批量测试全部 13 个 DoH 节点延迟 (基准跑分)
 4. 检测本机 DNS 连通性与测速 (多域名梯队延迟)
 5. 深度检测 DoH 综合服务状态 (端口/上游/系统全面排错)
 6. 卸载全部 DoH 工具并恢复默认配置
 0. 退出脚本
=======================================================
```

---

## 🌐 预置 13 大 DoH 节点列表

| 序号 | 节点标识 | 协议端点 (HTTPS) | 特性说明 |
| :--- | :--- | :--- | :--- |
| **1** | Google DNS (主) | `https://8.8.8.8/dns-query` | 纯 IP 直连，免 Bootstrap 解析 |
| **2** | Google DNS (备) | `https://8.8.4.4/dns-query` | 纯 IP 备用节点 |
| **3** | Cloudflare (主) | `https://1.1.1.1/dns-query` | 纯 IP 直连，全球 Anycast 低延迟 |
| **4** | Cloudflare (备) | `https://1.0.0.1/dns-query` | 纯 IP 备用节点 |
| **5** | Cloudflare 官方域名 | `https://cloudflare-dns.com/dns-query` | 官方标准主端点 |
| **6** | Cloudflare 备用域名 | `https://dns.cloudflare.com/dns-query` | 官方标准备用端点 |
| **7** | Quad9 主域名 | `https://dns.quad9.net/dns-query` | 恶意威胁与钓鱼自动拦截 |
| **8** | Quad9 备用域名 | `https://dns9.quad9.net/dns-query` | 支持 ECS 且无威胁过滤 |
| **9** | Cisco OpenDNS (主) | `https://doh.opendns.com/dns-query` | Cisco 官方公共端点 |
| **10** | Cisco OpenDNS (备) | `https://dns.opendns.com/dns-query` | Cisco 官方备用端点 |
| **11** | Cisco Umbrella (主) | `https://doh.umbrella.com/dns-query` | 企业级全球安全解析 |
| **12** | Cisco Umbrella (备) | `https://dns.umbrella.com/dns-query` | 企业级备用端点 |
| **13** | Cisco SSE | `https://dns.sse.cisco.com/dns-query` | Cisco SSE 边缘节点 |

---

## 🧹 卸载与清理

如需完全卸载服务并还原系统 DNS，可在脚本主菜单选择 **`6`**，或手动执行以下命令：

```bash
# 停止并清理 systemd 服务
systemctl disable --now dnsproxy cloudflared-dns 2>/dev/null || true
rm -f /etc/systemd/system/dnsproxy.service /etc/systemd/system/cloudflared-dns.service /etc/doh_custom.env
rm -f /usr/local/bin/dnsproxy /usr/local/bin/cloudflared
systemctl daemon-reload

# 还原默认上游 DNS
cat << 'EOF' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
```

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 授权许可开源。