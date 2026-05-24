# Xray VLESS 一键安装 & 管理脚本

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Xray Version](https://img.shields.io/badge/Xray-latest-blue)](https://github.com/XTLS/Xray-core)

在 VPS 上一键部署并管理 Xray VLESS 代理服务。

## 快速开始

```bash
bash <(curl -sL https://cdn.jsdelivr.net/gh/charmingyi/xray-vless-install@main/install.sh)
```

### 节点管理

```bash
# 管理已搭建的节点
bash install.sh --manage
```

## 三种方案

| # | 方案 | 特点 | 适用场景 |
|---|------|------|----------|
| 1 | **VLESS + REALITY** | 流量伪装 HTTPS，无需域名证书 | 直接过墙 ✅ 推荐 |
| 2 | **VLESS + Encryption** | ML-KEM-768 后量子加密，前向安全 | CDN / 中转 / non-TLS |
| 3 | VLESS 基础版 | 明文传输 | 测试/内网 |

## 管理功能 (`--manage`)

- 查看节点状态（运行状态、连接数、流量统计）
- 查看完整配置 & 重新生成分享链接
- 启动/停止/重启 服务
- 查看实时日志
- 修改监听端口（自动更新防火墙）
- 一键更新 Xray 核心

## 系统要求

- Debian 9+ / Ubuntu 18.04+ / CentOS 7+
- x86_64 / arm64
- root 权限

## 命令行管理

```bash
systemctl status xray        # 状态
systemctl restart xray       # 重启
journalctl -u xray -f        # 实时日志
```

## 文件位置

| 文件 | 路径 |
|------|------|
| 配置 | `/usr/local/etc/xray/config.json` |
| 链接 | `/usr/local/etc/xray/vless-link.txt` |
| 日志 | `/var/log/xray/access.log` |

## 技术参考

- [VLESS Encryption PR #5067](https://github.com/XTLS/Xray-core/pull/5067)
- [REALITY](https://xtls.github.io/en/config/transports/reality.html)
- [Xray 官方文档](https://xtls.github.io/)

## License

MIT
