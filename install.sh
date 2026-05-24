#!/bin/bash
#=============================================================================
# Xray VLESS 一键安装脚本
# 支持: VLESS + REALITY | VLESS + Encryption (PR #5067) | VLESS 基础版
# Author: JJQQA / David Tao
# License: MIT
# Repo: https://github.com/jjqqa/xray-vless-install
#=============================================================================

set -eo pipefail

#=============================================================================
# 颜色 & 常量
#=============================================================================
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'
CYAN='\033[36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}${BLUE}==>${NC}${BOLD} $*${NC}"; }
ask()     { echo -e "${CYAN}[?]${NC} $*"; }

#=============================================================================
# 预检
#=============================================================================
pre_check() {
    step "环境检查"

    [[ $EUID -ne 0 ]] && error "请用 root 用户运行: sudo bash install.sh"
    [[ $(uname -m) != "x86_64" && $(uname -m) != "aarch64" ]] && error "仅支持 x86_64 / arm64 架构"

    # 检测包管理器
    if command -v apt-get &>/dev/null; then
        PKG_MGR="apt-get"
        PKG_UPDATE="apt-get update -qq"
        PKG_INSTALL="apt-get install -y -qq"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
        PKG_UPDATE="yum makecache -q"
        PKG_INSTALL="yum install -y -q"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
        PKG_UPDATE="dnf makecache -q"
        PKG_INSTALL="dnf install -y -q"
    else
        error "未检测到 apt-get / yum / dnf，不支持此系统"
    fi
    info "系统: $(cat /etc/os-release | grep ^PRETTY_NAME | cut -d'"' -f2)"
    info "架构: $(uname -m) | 包管理: $PKG_MGR"
}

#=============================================================================
# 安装依赖
#=============================================================================
install_deps() {
    step "安装基础依赖"
    $PKG_UPDATE
    $PKG_INSTALL curl wget unzip jq ca-certificates socat 2>/dev/null || true
    info "依赖安装完成"
}

#=============================================================================
# 安装 Xray-core
#=============================================================================
install_xray() {
    step "安装 Xray-core 最新版"

    # 获取最新版本
    XRAY_VERSION=$(curl -sL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r '.tag_name')
    [[ -z "$XRAY_VERSION" || "$XRAY_VERSION" == "null" ]] && XRAY_VERSION="v25.3.6"
    info "最新版本: $XRAY_VERSION"

    # 架构映射
    case $(uname -m) in
        x86_64)  ARCH="64" ;;
        aarch64) ARCH="arm64-v8a" ;;
        *)       error "不支持的架构" ;;
    esac

    DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${ARCH}.zip"

    TMPDIR=$(mktemp -d)
    cd "$TMPDIR"
    curl -sL "$DOWNLOAD_URL" -o xray.zip || error "下载 Xray 失败"
    unzip -q xray.zip

    mkdir -p /usr/local/share/xray
    cp xray /usr/local/bin/xray
    chmod +x /usr/local/bin/xray
    cp geoip.dat geosite.dat /usr/local/share/xray/ 2>/dev/null || true

    # 安装 xray 命令到 PATH（如果还没在）
    [[ ! -f /usr/local/bin/xray ]] && error "Xray 安装失败"

    # 验证
    INSTALLED_VER=$(/usr/local/bin/xray version 2>&1 | head -1 | grep -oP 'v?\d+\.\d+\.\d+' || echo "unknown")
    info "Xray 已安装: $INSTALLED_VER"

    cd /tmp && rm -rf "$TMPDIR"
}

#=============================================================================
# 目录结构
#=============================================================================
setup_dirs() {
    step "创建目录结构"
    XRAY_DIR="/usr/local/etc/xray"
    XRAY_LOG="/var/log/xray"

    mkdir -p "$XRAY_DIR" "$XRAY_LOG"

    # 生成固定配置文件
    XRAY_CONFIG="$XRAY_DIR/config.json"
    info "配置目录: $XRAY_DIR"
}

#=============================================================================
# 工具函数: 生成随机字符串
#=============================================================================
random_hex() {
    local len=${1:-16}
    openssl rand -hex "$len" 2>/dev/null || head -c $((len*2)) /dev/urandom | xxd -p
}

random_port() {
    echo $(( RANDOM % 30000 + 10000 ))
}

#=============================================================================
# REALITY 配置
#=============================================================================
config_reality() {
    step "配置 VLESS + REALITY"

    PORT=${REALITY_PORT:-$(random_port)}
    read -rp "$(ask "VLESS 端口 (默认: $PORT): ")" input
    PORT=${input:-$PORT}

    # 生成 REALITY 密钥对
    info "生成 REALITY X25519 密钥对..."
    REALITY_KEYS=$(/usr/local/bin/xray x25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep -oP 'PrivateKey:\s*\K\S+')
    PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep -oP 'Password:\s*\K\S+')
    [[ -z "$PRIVATE_KEY" ]] && error "生成 REALITY 密钥失败"

    # 生成 UUID
    UUID=$(/usr/local/bin/xray uuid 2>/dev/null)
    [[ -z "$UUID" ]] && error "生成 UUID 失败"

    # ShortId
    SHORT_ID=$(random_hex 8)
    # 生成另一个 shortId 用于多 shortIds
    SHORT_ID2=$(random_hex 8)

    # REALITY 目标站点推荐
    echo ""
    echo -e "${YELLOW}REALITY 伪装站点建议 (选择一个未被墙的国外大站):${NC}"
    echo "  1. www.microsoft.com  (推荐, 稳定)"
    echo "  2. www.apple.com"
    echo "  3. www.amazon.com"
    echo "  4. cloudflare.com"
    echo "  5. 自定义输入"
    read -rp "$(ask "选择 [1-5] (默认: 1): ")" dest_choice
    case ${dest_choice:-1} in
        1) DEST="www.microsoft.com:443" ; SNI="www.microsoft.com" ;;
        2) DEST="www.apple.com:443"     ; SNI="www.apple.com" ;;
        3) DEST="www.amazon.com:443"    ; SNI="www.amazon.com" ;;
        4) DEST="cloudflare.com:443"    ; SNI="cloudflare.com" ;;
        5) read -rp "$(ask "输入目标 (如 example.com:443): ")" DEST
           SNI="${DEST%:*}" ;;
        *) DEST="www.microsoft.com:443" ; SNI="www.microsoft.com" ;;
    esac
    info "REALITY 伪装目标: $DEST"

    # 写入服务端配置
    cat > "$XRAY_CONFIG" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST",
          "xver": 0,
          "serverNames": ["$SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID", "$SHORT_ID2"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

    # 生成分享链接 (VLESS REALITY 格式)
    REALITY_LINK="vless://${UUID}@$(curl -s4 ifconfig.me 2>/dev/null || echo 'YOUR_IP'):${PORT}?flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F&type=raw&headerType=none#VLESS-REALITY-$(hostname 2>/dev/null || echo 'VPS')"

    # 打印客户端配置
    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  VLESS + REALITY 服务端配置完成!${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}服务端信息:${NC}"
    echo -e "  协议:       ${YELLOW}VLESS + REALITY${NC}"
    echo -e "  地址:       ${CYAN}$(curl -s4 ifconfig.me 2>/dev/null || echo 'YOUR_IP')${NC}"
    echo -e "  端口:       ${CYAN}$PORT${NC}"
    echo -e "  UUID:       ${CYAN}$UUID${NC}"
    echo -e "  Flow:       ${CYAN}xtls-rprx-vision${NC}"
    echo -e "  PublicKey:  ${CYAN}$PUBLIC_KEY${NC}"
    echo -e "  ShortId:    ${CYAN}$SHORT_ID${NC}"
    echo -e "  SNI:        ${CYAN}$SNI${NC}"
    echo -e "  Fingerprint:${CYAN}chrome${NC}"
    echo ""
    echo -e "${BOLD}VLESS 分享链接 (客户端导入):${NC}"
    echo -e "${GREEN}$REALITY_LINK${NC}"
    echo ""
    echo -e "${BOLD}NekoBox / v2rayN JSON 配置片段:${NC}"
    cat << 'CLIENTJSON'
{
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "SERVER_IP",
        "port": SERVER_PORT,
        "users": [{
          "id": "UUID",
          "flow": "xtls-rprx-vision",
          "encryption": "none"
        }]
      }]
    },
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "serverName": "SNI",
        "fingerprint": "chrome",
        "password": "PUBLIC_KEY",
        "shortId": "SHORT_ID",
        "spiderX": "/"
      }
    }
  }]
}
CLIENTJSON
    echo ""

    # 保存分享链接到文件
    echo "$REALITY_LINK" > "$XRAY_DIR/vless-link.txt"
}

#=============================================================================
# VLESS Encryption 配置 (PR #5067)
#=============================================================================
config_encryption() {
    step "配置 VLESS + Encryption (PR #5067)"

    PORT=${ENC_PORT:-$(random_port)}
    read -rp "$(ask "VLESS 端口 (默认: $PORT): ")" input
    PORT=${input:-$PORT}

    # 生成 UUID
    UUID=$(/usr/local/bin/xray uuid 2>/dev/null)
    [[ -z "$UUID" ]] && error "生成 UUID 失败"

    # 生成加密密钥 (ML-KEM-768 后量子密钥交换)
    info "生成 ML-KEM-768 后量子密钥..."
    MLKEM_OUTPUT=$(/usr/local/bin/xray mlkem768 2>/dev/null)
    MLKEM_SEED=$(echo "$MLKEM_OUTPUT" | grep -oP 'Seed:\s*\K\S+')
    MLKEM_CLIENT=$(echo "$MLKEM_OUTPUT" | grep -oP 'Client:\s*\K\S+')
    MLKEM_HASH32=$(echo "$MLKEM_OUTPUT" | grep -oP 'Hash32:\s*\K\S+')

    if [[ -z "$MLKEM_SEED" ]]; then
        warn "mlkem768 命令不支持，降级使用 x25519"
        X25519_OUTPUT=$(/usr/local/bin/xray x25519 2>/dev/null)
        MLKEM_SEED=$(echo "$X25519_OUTPUT" | grep -oP 'PrivateKey:\s*\K\S+')
    fi
    [[ -z "$MLKEM_SEED" ]] && error "生成加密密钥失败"

    # 加密模式选择
    echo ""
    echo -e "${YELLOW}VLESS Encryption 加密模式:${NC}"
    echo "  1. native  - 原始格式包 (头部有公钥特征, 非全随机)"
    echo "  2. xorpub  - 混淆公钥部分 (隐藏 X25519/ML-KEM 特征)"
    echo "  3. random  - 全随机外观 (类似 VMess/SS, 成本约万分之六)"
    echo ""
    read -rp "$(ask "选择 [1-3] (默认: 3, random): ")" enc_choice
    case ${enc_choice:-3} in
        1) ENC_MODE="native" ;;
        2) ENC_MODE="xorpub" ;;
        3) ENC_MODE="random" ;;
        *) ENC_MODE="random" ;;
    esac

    # Ticket 复用时间
    read -rp "$(ask "Ticket 复用时间(秒) / 1rtt 禁止复用 (默认: 600s): ")" ticket_time
    ticket_time=${ticket_time:-"600s"}

    # 构建 decryption 字符串
    # 格式: mlkem768x25519plus.<mode>.<ticket>.<padding>.<seed_key>
    # padding 格式: probability-min-max.probability-min-max...
    DECRYPTION="mlkem768x25519plus.${ENC_MODE}.${ticket_time}.100-111-1111.75-0-111.50-0-3333.${MLKEM_SEED}"

    info "Decryption: ${DECRYPTION:0:80}..."

    # 写入服务端配置
    cat > "$XRAY_CONFIG" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID"
          }
        ],
        "decryption": "$DECRYPTION"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

    # 构建客户端 decryption（客户端使用相同的格式）
    CLIENT_DECRYPTION="$DECRYPTION"

    # 生成 VLESS 链接
    SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || echo 'YOUR_IP')
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&type=raw#VLESS-Enc-${ENC_MODE}-$(hostname 2>/dev/null || echo 'VPS')"

    # 打印客户端配置
    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  VLESS + Encryption 服务端配置完成!${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}服务端信息:${NC}"
    echo -e "  协议:       ${YELLOW}VLESS + Encryption (PR #5067)${NC}"
    echo -e "  地址:       ${CYAN}$SERVER_IP${NC}"
    echo -e "  端口:       ${CYAN}$PORT${NC}"
    echo -e "  UUID:       ${CYAN}$UUID${NC}"
    echo -e "  加密模式:   ${CYAN}$ENC_MODE${NC}"
    echo -e "  Ticket:     ${CYAN}$ticket_time${NC}"
    echo ""
    echo -e "${BOLD}客户端 JSON 配置 (v2rayN / NekoBox):${NC}"
    cat << CLIENTJSON
{
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "$SERVER_IP",
        "port": $PORT,
        "users": [{
          "id": "$UUID",
          "encryption": "none",
          "decryption": "$CLIENT_DECRYPTION"
        }]
      }]
    },
    "streamSettings": {
      "network": "raw"
    }
  }]
}
CLIENTJSON

    echo ""
    echo -e "${YELLOW}⚠ 注意: VLESS Encryption 并非设计用于直接过墙${NC}"
    echo -e "${YELLOW}   推荐场景: CDN / 中转 / non-TLS 环境 / 绕机场审计${NC}"
    echo -e "${YELLOW}   直接过墙请使用 VLESS + REALITY 方案${NC}"
    echo ""
}

#=============================================================================
# VLESS 基础配置
#=============================================================================
config_basic() {
    step "配置 VLESS 基础版"

    PORT=${BASIC_PORT:-$(random_port)}
    read -rp "$(ask "VLESS 端口 (默认: $PORT): ")" input
    PORT=${input:-$PORT}

    UUID=$(/usr/local/bin/xray uuid 2>/dev/null)
    [[ -z "$UUID" ]] && error "生成 UUID 失败"

    cat > "$XRAY_CONFIG" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID"
          }
        ],
        "decryption": "none"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

    SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || echo 'YOUR_IP')
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&type=raw#VLESS-Basic-$(hostname 2>/dev/null || echo 'VPS')"

    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  VLESS 基础版 配置完成!${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}服务端信息:${NC}"
    echo -e "  协议:       ${YELLOW}VLESS (明文, 无加密)${NC}"
    echo -e "  地址:       ${CYAN}$SERVER_IP${NC}"
    echo -e "  端口:       ${CYAN}$PORT${NC}"
    echo -e "  UUID:       ${CYAN}$UUID${NC}"
    echo ""
    echo -e "${YELLOW}⚠ 警告: 明文 VLESS 没有加密保护，不推荐直接使用${NC}"
    echo -e "${YELLOW}   建议选择 REALITY 或 Encryption 方案${NC}"
    echo ""
}

#=============================================================================
# systemd 服务
#=============================================================================
setup_service() {
    step "配置 systemd 服务"

    cat > /etc/systemd/system/xray.service << 'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray --now

    sleep 2
    if systemctl is-active --quiet xray; then
        info "Xray 服务运行中 ✓"
    else
        warn "Xray 服务启动失败，检查: systemctl status xray"
        systemctl status xray --no-pager -l
    fi
}

#=============================================================================
# BBR 优化 (可选)
#=============================================================================
setup_bbr() {
    step "优化内核参数 (BBR)"

    # 启用 BBR 拥塞控制
    if lsmod | grep -q tcp_bbr; then
        info "BBR 已启用"
    else
        modprobe tcp_bbr 2>/dev/null || true
        echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || true
    fi

    # 检查当前内核是否支持 BBR
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$CURRENT_CC" != "bbr" ]]; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
        info "BBR 拥塞控制已设置 ($(sysctl -n net.ipv4.tcp_congestion_control))"
    else
        info "BBR 已启用 ($CURRENT_CC)"
    fi
}

#=============================================================================
# 防火墙 (自动开端口)
#=============================================================================
setup_firewall() {
    step "配置防火墙"

    # iptables
    if command -v iptables &>/dev/null; then
        if iptables -L | grep -qP "DROP|REJECT"; then
            warn "检测到 iptables 有拦截规则，请手动放行端口"
        fi
    fi

    # ufw
    if command -v ufw &>/dev/null; then
        if ufw status | grep -q "active"; then
            PORT=$(grep -oP '(?<="port": )\d+' "$XRAY_CONFIG" | head -1)
            ufw allow "$PORT"/tcp 2>/dev/null || true
            info "ufw 已放行端口 $PORT"
        fi
    fi

    # firewalld
    if command -v firewall-cmd &>/dev/null; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            PORT=$(grep -oP '(?<="port": )\d+' "$XRAY_CONFIG" | head -1)
            firewall-cmd --permanent --add-port="$PORT"/tcp 2>/dev/null || true
            firewall-cmd --reload 2>/dev/null || true
            info "firewalld 已放行端口 $PORT"
        fi
    fi

    # VPS 云防火墙提示
    echo ""
    echo -e "${YELLOW}⚠ 如果你的 VPS 有外部防火墙（如阿里云安全组/腾讯云防火墙），${NC}"
    echo -e "${YELLOW}   请务必在控制台放行端口: $PORT${NC}"
}

#=============================================================================
# 显示管理命令
#=============================================================================
show_commands() {
    PORT=$(grep -oP '(?<="port": )\d+' "$XRAY_CONFIG" | head -1)
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  Xray 管理命令${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  启动:       ${GREEN}systemctl start xray${NC}"
    echo -e "  停止:       ${GREEN}systemctl stop xray${NC}"
    echo -e "  重启:       ${GREEN}systemctl restart xray${NC}"
    echo -e "  状态:       ${GREEN}systemctl status xray${NC}"
    echo -e "  日志:       ${GREEN}journalctl -u xray -f${NC}"
    echo -e "  配置文件:   ${GREEN}$XRAY_CONFIG${NC}"
    echo -e "  分享链接:   ${GREEN}$XRAY_DIR/vless-link.txt${NC}"
    echo -e "  监听端口:   ${CYAN}$PORT${NC}"
    echo ""
}

#=============================================================================
# 主菜单
#=============================================================================
main_menu() {
    clear
    echo -e "${BOLD}${BLUE}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║     Xray VLESS 一键安装脚本                          ║"
    echo "║     支持: REALITY | Encryption(PR#5067) | 基础版    ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo "  1. VLESS + REALITY    (推荐 - 直接过墙, 伪装流量)"
    echo "  2. VLESS + Encryption (PR #5067 - 后量子加密, 适合 CDN/中转)"
    echo "  3. VLESS 基础版       (明文, 不推荐)"
    echo "  4. 退出"
    echo ""
    read -rp "$(ask "请选择 [1-4]: ")" choice

    case $choice in
        1) config_type="reality" ;;
        2) config_type="encryption" ;;
        3) config_type="basic" ;;
        4) echo "退出"; exit 0 ;;
        *) error "无效选择" ;;
    esac
}

#=============================================================================
# 汇总信息
#=============================================================================
summary() {
    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  安装完成! 享受安全的代理服务 ${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    case $config_type in
        reality)
            echo -e "  方案: ${GREEN}VLESS + REALITY${NC} — 流量伪装为 HTTPS 浏览"
            echo -e "  端口: ${CYAN}$PORT${NC}"
            echo -e "  UUID: ${CYAN}$UUID${NC}"
            echo ""
            echo -e "  ${YELLOW}客户端需配置:${NC}"
            echo -e "    - flow: xtls-rprx-vision"
            echo -e "    - security: reality"
            echo -e "    - publicKey (password): $PUBLIC_KEY"
            echo -e "    - shortId: $SHORT_ID"
            echo -e "    - serverName (sni): $SNI"
            echo -e "    - fingerprint: chrome"
            ;;
        encryption)
            echo -e "  方案: ${GREEN}VLESS + Encryption (PR #5067)${NC} — ML-KEM-768 后量子加密"
            echo -e "  端口: ${CYAN}$PORT${NC}"
            echo -e "  UUID: ${CYAN}$UUID${NC}"
            echo -e "  模式: ${CYAN}$ENC_MODE${NC}"
            echo ""
            echo -e "  ${YELLOW}⚠ 适用场景: CDN / 中转 / non-TLS / 绕机场审计${NC}"
            echo -e "  ${YELLOW}   直接过墙请用 REALITY 方案${NC}"
            ;;
        basic)
            echo -e "  方案: ${GREEN}VLESS 基础版${NC} (无加密)"
            echo -e "  端口: ${CYAN}$PORT${NC}"
            echo -e "  UUID: ${CYAN}$UUID${NC}"
            ;;
    esac

    echo ""
}

#=============================================================================
# 入口
#=============================================================================
main() {
    pre_check
    install_deps
    install_xray
    setup_dirs

    main_menu

    case $config_type in
        reality)    config_reality ;;
        encryption) config_encryption ;;
        basic)      config_basic ;;
    esac

    setup_firewall
    setup_service
    setup_bbr
    show_commands
    summary
}

main "$@"
