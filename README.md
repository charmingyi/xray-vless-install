# Xray VLESS 一键安装脚本

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Xray Version](https://img.shields.io/badge/Xray-latest-blue)](https://github.com/XTLS/Xray-core)

在 VPS 上一键部署 Xray VLESS 代理服务，支持三种方案：

| 方案 | 特点 | 适用场景 |
|------|------|----------|
| **VLESS + REALITY** | 流量伪装为 HTTPS 浏览，抗主动探测 | 直接过墙 (推荐) |
| **VLESS + Encryption** | 基于 ML-KEM-768 后量子密钥交换的 AEAD 加密 | CDN / 中转 / non-TLS |
| **VLESS 基础版** | 明文传输 | 内网 / 测试 |

## 快速开始

```bash
bash <(curl -sL https://raw.githubusercontent.com/charmingyi/xray-vless-install/main/install.sh)
```

或手动：

```bash
wget https://raw.githubusercontent.com/charmingyi/xray-vless-install/main/install.sh
chmod +x install.sh
sudo bash install.sh
```

## 方案说明

### 1. VLESS + REALITY (推荐)

- **原理**: 利用 REALITY 协议将 VLESS 流量伪装成与目标网站的正常 HTTPS 通信
- **优点**: 无需域名、无需证书、流量外观与普通浏览无异
- **配置**: 脚本自动生成 X25519 密钥对、UUID、ShortId
- **客户端**: v2rayN / NekoBox / Shadowrocket / Streisand 等支持 REALITY 的客户端

### 2. VLESS + Encryption (PR #5067)

- **原理**: 在 VLESS 协议层外包裹一层加密连接 (conn wrapper)
- **技术**: ML-KEM-768 后量子密钥交换 + X25519，提供前向安全且抗量子破解
- **三种模式**:
  - `native` — 原始格式包，头部有公钥特征
  - `xorpub` — 混淆公钥部分
  - `random` — 全随机外观 (类似 VMess/Shadowsocks)
- **Ticket 复用**: 支持 0-RTT，复用时间内无需重新握手
- **适用**: CDN、中转、禁用 HTTP/TLS 的伊朗等环境
- **注意**: 此方案并非设计用于直接过墙，直接过墙请用 REALITY

### 3. VLESS 基础版

- 最简配置，无加密无伪装
- 仅适合内网测试或配合上层加密使用

## 系统要求

- **系统**: Debian 9+ / Ubuntu 18.04+ / CentOS 7+ / Rocky Linux 8+
- **架构**: x86_64 / arm64
- **权限**: root
- **内存**: ≥ 256MB

## 安装后管理

```bash
# 查看状态
systemctl status xray

# 查看日志
journalctl -u xray -f

# 重启
systemctl restart xray

# 查看分享链接
cat /usr/local/etc/xray/vless-link.txt
```

## 配置文件位置

| 文件 | 路径 |
|------|------|
| Xray 配置 | `/usr/local/etc/xray/config.json` |
| 分享链接 | `/usr/local/etc/xray/vless-link.txt` |
| 访问日志 | `/var/log/xray/access.log` |
| 错误日志 | `/var/log/xray/error.log` |

## 技术参考

- [VLESS Encryption PR #5067](https://github.com/XTLS/Xray-core/pull/5067) — RPRX 设计文档
- [REALITY PR #4915](https://github.com/XTLS/Xray-core/pull/4915)
- [Xray 官方文档](https://xtls.github.io/)
- [Xray-core GitHub](https://github.com/XTLS/Xray-core)

## 致谢

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) — Xray 项目
- [RPRX](https://github.com/RPRX) — VLESS/REALITY/VLESS Encryption 作者

## License

MIT
