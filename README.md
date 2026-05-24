# Xray VLESS 一键安装 & 管理

```bash
bash <(curl -sL "https://raw.githubusercontent.com/charmingyi/xray-vless-install/main/install.sh?t=$(date +%s)")
```

## 方案

| # | 方案 | 适用 |
|---|------|------|
| 1 | VLESS + REALITY | 直接过墙 ✅ |
| 2 | VLESS + Encryption (xray vlessenc) | CDN / 中转 |
| 3 | VLESS 基础版 | 测试 |

## 特性

- `xray vlessenc` 官方命令生成后量子密钥对
- 多节点共存 (jq 追加 inbounds，不覆盖)
- share link 可直接导入客户端
- systemd / openrc 双支持
- 缺少依赖直接 curl .deb (不碰 apt 源)
- Loyalsoldier GeoData

## 管理

```bash
bash install.sh
# 已安装 → 直进管理面板
```
