#!/bin/bash
#=============================================================================
# Xray VLESS 一键安装 & 管理脚本
# 支持: VLESS + REALITY | VLESS + Encryption (PR #5067) | VLESS 基础版
# Author: JJQQA / David Tao
# License: MIT
# Repo: https://github.com/charmingyi/xray-vless-install
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

# 常量路径
XRAY_DIR="/usr/local/etc/xray"
XRAY_LOG="/var/log/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_BIN="/usr/local/bin/xray"

#=============================================================================
# 通用的 JSON 读取（优先 jq，降级 python3）
#=============================================================================
json_get() {
    local key="$1" file="${2:-$XRAY_CONFIG}"
    if command -v jq &>/dev/null; then
        jq -r "$key" "$file" 2>/dev/null
    elif command -v python3 &>/dev/null; then
        python3 -c "import json; d=json.load(open('$file')); print(d$key)" 2>/dev/null
    else
        grep -oP "(?<=\"${key##*.}\": )\"?[^\",}]*\"?" "$file" 2>/dev/null | head -1 | tr -d '"'
    fi
}

#=============================================================================
# 获取服务器公网 IP（强制 IPv4）
#=============================================================================
get_ip() {
    curl -s4 ifconfig.me 2>/dev/null \
        || curl -s4 ip.sb 2>/dev/null \
        || curl -s4 icanhazip.com 2>/dev/null \
        || echo 'YOUR_IP'
}

#=============================================================================
# 预检
#=============================================================================
pre_check() {
    step "环境检查"

    [[ $EUID -ne 0 ]] && error "请用 root 用户运行: sudo bash install.sh"
    local arch=$(uname -m)
    [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]] && error "仅支持 x86_64 / arm64 架构"

    # 检测包管理器
    if command -v apt-get &>/dev/null; then
        PKG_MGR="apt-get"
        PKG_UPDATE="apt-get update"
        PKG_INSTALL="apt-get install -y"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
        PKG_UPDATE="yum makecache"
        PKG_INSTALL="yum install -y"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
        PKG_UPDATE="dnf makecache"
        PKG_INSTALL="dnf install -y"
    else
        error "未检测到 apt-get / yum / dnf，不支持此系统"
    fi
    info "系统: $(grep ^PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    info "架构: $arch | 包管理: $PKG_MGR"
}

#=============================================================================
# 安装依赖（显示实时进度，IPv4 强制，镜像故障自动回退）
#=============================================================================
install_deps() {
    step "安装基础依赖"

    # --- apt 专用：强制 IPv4 + 修复 DNS 问题 ---
    if [[ "$PKG_MGR" == "apt-get" ]]; then
        # 写 apt 配置文件强制 IPv4（比 -o 参数更可靠，对所有源生效）
        mkdir -p /etc/apt/apt.conf.d
        cat > /etc/apt/apt.conf.d/99-xray-install << 'APTEOF'
Acquire::ForceIPv4 "true";
Acquire::http::Timeout "10";
Acquire::https::Timeout "10";
Acquire::Retries "3";
APTEOF
        info "已配置 apt 强制 IPv4"

        # 检测当前镜像源是否可达（中国 VPS 常见：清华/阿里/中科大）
        echo -e "${CYAN}检测镜像源连通性...${NC}"
        local mirrors_ok=true
        if ! timeout 5 curl -sI https://mirrors.tuna.tsinghua.edu.cn/ >/dev/null 2>&1 && \
           ! timeout 5 curl -sI http://mirrors.tuna.tsinghua.edu.cn/ >/dev/null 2>&1; then
            mirrors_ok=false
        fi

        # 如果默认镜像不通，切换为 Debian 官方 CDN（自动路由到最近节点）
        if ! $mirrors_ok; then
            warn "当前镜像源不可达，切换为 Debian 官方源"
            local codename=$(grep VERSION_CODENAME /etc/os-release 2>/dev/null | cut -d= -f2)
            [[ -z "$codename" ]] && codename="bookworm"
            cat > /etc/apt/sources.list << SRCEOF
deb http://deb.debian.org/debian ${codename} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${codename}-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security ${codename}-security main contrib non-free non-free-firmware
SRCEOF
            # 如果存在 mirror 配置也清掉避免干扰
            rm -f /etc/apt/mirrors/debian.list /etc/apt/mirrors/debian-security.list 2>/dev/null
            info "已切换为: http://deb.debian.org/debian"
        fi

        # 执行 apt update，捕获错误但不退出
        echo -e "${CYAN}正在更新软件源...${NC}"
        local update_failed=false
        $PKG_UPDATE 2>&1 | while IFS= read -r line; do
            if [[ "$line" == *"Get:"* || "$line" == *"Hit:"* || "$line" == *"Fetched"* || "$line" == *"Reading"* || "$line" == *"Building"* ]]; then
                echo -e "  ${GREEN}▸${NC} $line"
            elif [[ "$line" == *"Err:"* || "$line" == *"Failed"* || "$line" == *"Unable to connect"* ]]; then
                echo -e "  ${RED}✗${NC} $line"
            elif [[ "$line" == *"W:"* ]]; then
                echo -e "  ${YELLOW}⚠${NC} $line"
            fi
        done
        local ret=${PIPESTATUS[0]}
        if [[ $ret -ne 0 ]]; then
            warn "apt update 返回错误码 $ret，尝试继续..."
        fi

        # 安装包
        echo -e "${CYAN}正在安装依赖包 (curl wget unzip socat ca-certificates)...${NC}"
        $PKG_INSTALL curl wget unzip socat ca-certificates 2>&1 | while IFS= read -r line; do
            if [[ "$line" =~ (Setting\ up|Unpacking|Installing|Selecting|Get:) ]]; then
                echo -e "  ${GREEN}▸${NC} $line"
            elif [[ "$line" == *"Err:"* || "$line" == *"Failed"* ]]; then
                echo -e "  ${RED}✗${NC} $line"
            fi
        done
        if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
            warn "部分依赖包安装失败，尝试继续..."
        fi

    # --- yum/dnf ---
    else
        echo -e "${CYAN}正在更新软件源...${NC}"
        $PKG_UPDATE 2>&1 | while IFS= read -r line; do
            if [[ "$line" =~ (Downloading|Installing|Updating|Metadata) ]]; then
                echo -e "  ${GREEN}▸${NC} $line"
            fi
        done

        echo -e "${CYAN}正在安装依赖包...${NC}"
        $PKG_INSTALL curl wget unzip socat ca-certificates 2>&1 | while IFS= read -r line; do
            if [[ "$line" =~ (Installing|Downloading) ]]; then
                echo -e "  ${GREEN}▸${NC} $line"
            fi
        done
    fi

    # 确保 python3 可用于 JSON 解析（jq 的降级方案）
    if ! command -v python3 &>/dev/null; then
        echo -e "${CYAN}安装 python3...${NC}"
        if [[ "$PKG_MGR" == "apt-get" ]]; then
            apt-get install -y python3 2>/dev/null || true
        else
            $PKG_INSTALL python3 2>/dev/null || true
        fi
    fi

    info "依赖安装完成"
}

#=============================================================================
# 安装 Xray-core
#=============================================================================
install_xray() {
    step "安装 Xray-core 最新版"

    # 不依赖 jq，用 python3 或 grep 解析版本
    local api_resp=$(curl -sL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null)
    XRAY_VERSION=$(echo "$api_resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null \
        || echo "$api_resp" | grep -oP '"tag_name":\s*"\K[^"]+' 2>/dev/null \
        || echo "")

    [[ -z "$XRAY_VERSION" ]] && XRAY_VERSION="v25.3.6"
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

    echo -e "${CYAN}下载中... $DOWNLOAD_URL${NC}"
    curl -#L "$DOWNLOAD_URL" -o xray.zip || error "下载 Xray 失败"
    unzip -q xray.zip
    echo -e "${GREEN}▸${NC} 解压完成"

    mkdir -p /usr/local/share/xray
    cp xray "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    cp geoip.dat geosite.dat /usr/local/share/xray/ 2>/dev/null || true

    [[ ! -f "$XRAY_BIN" ]] && error "Xray 安装失败"

    INSTALLED_VER=$("$XRAY_BIN" version 2>&1 | head -1 | grep -oP 'v?\d+\.\d+\.\d+' || echo "unknown")
    info "Xray 已安装: $INSTALLED_VER"

    cd /tmp && rm -rf "$TMPDIR"
}

#=============================================================================
# 目录结构
#=============================================================================
setup_dirs() {
    mkdir -p "$XRAY_DIR" "$XRAY_LOG"
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
    REALITY_KEYS=$("$XRAY_BIN" x25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep -oP 'PrivateKey:\s*\K\S+')
    PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep -oP 'Password:\s*\K\S+')
    [[ -z "$PRIVATE_KEY" ]] && error "生成 REALITY 密钥失败"

    UUID=$("$XRAY_BIN" uuid 2>/dev/null)
    [[ -z "$UUID" ]] && error "生成 UUID 失败"

    SHORT_ID=$(random_hex 8)
    SHORT_ID2=$(random_hex 8)

    # 目标站点选择
    echo ""
    echo -e "${YELLOW}REALITY 伪装站点建议 (选一个未被墙的国外大站):${NC}"
    echo "  1. www.microsoft.com  (推荐)"
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

    # 保存方案类型
    PROTO_TYPE="reality"

    cat > "$XRAY_CONFIG" << JSONEOF
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
      "tag": "vless-in",
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
JSONEOF

    # 保存元信息
    cat > "$XRAY_DIR/.node-info" << METAEOF
TYPE=$PROTO_TYPE
PORT=$PORT
UUID=$UUID
SNI=$SNI
PUBLIC_KEY=$PUBLIC_KEY
PRIVATE_KEY=$PRIVATE_KEY
SHORT_ID=$SHORT_ID
SHORT_ID2=$SHORT_ID2
DEST=$DEST
INSTALL_TIME=$(date '+%Y-%m-%d %H:%M:%S')
METAEOF

    SERVER_IP=$(get_ip)
    REALITY_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F&type=raw&headerType=none#VLESS-REALITY-$(hostname 2>/dev/null || echo 'VPS')"
    echo "$REALITY_LINK" > "$XRAY_DIR/vless-link.txt"

    # 打印结果
    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  VLESS + REALITY 服务端配置完成!${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  协议:       ${YELLOW}VLESS + REALITY${NC}"
    echo -e "  地址:       ${CYAN}$SERVER_IP${NC}"
    echo -e "  端口:       ${CYAN}$PORT${NC}"
    echo -e "  UUID:       ${CYAN}$UUID${NC}"
    echo -e "  Flow:       ${CYAN}xtls-rprx-vision${NC}"
    echo -e "  PublicKey:  ${CYAN}$PUBLIC_KEY${NC}"
    echo -e "  ShortId:    ${CYAN}$SHORT_ID${NC}"
    echo -e "  SNI:        ${CYAN}$SNI${NC}"
    echo -e "  Fingerprint:${CYAN}chrome${NC}"
    echo ""
    echo -e "${BOLD}VLESS 分享链接:${NC}"
    echo -e "${GREEN}$REALITY_LINK${NC}"
}

#=============================================================================
# VLESS Encryption 配置 (PR #5067)
#=============================================================================
config_encryption() {
    step "配置 VLESS + Encryption (PR #5067)"

    PORT=${ENC_PORT:-$(random_port)}
    read -rp "$(ask "VLESS 端口 (默认: $PORT): ")" input
    PORT=${input:-$PORT}

    UUID=$("$XRAY_BIN" uuid 2>/dev/null)
    [[ -z "$UUID" ]] && error "生成 UUID 失败"

    # 生成加密密钥
    info "生成 ML-KEM-768 后量子密钥..."
    MLKEM_OUTPUT=$("$XRAY_BIN" mlkem768 2>/dev/null)
    MLKEM_SEED=$(echo "$MLKEM_OUTPUT" | grep -oP 'Seed:\s*\K\S+')

    if [[ -z "$MLKEM_SEED" ]]; then
        warn "mlkem768 命令不支持，降级使用 x25519"
        X25519_OUTPUT=$("$XRAY_BIN" x25519 2>/dev/null)
        MLKEM_SEED=$(echo "$X25519_OUTPUT" | grep -oP 'PrivateKey:\s*\K\S+')
    fi
    [[ -z "$MLKEM_SEED" ]] && error "生成加密密钥失败"

    # 加密模式
    echo ""
    echo -e "${YELLOW}VLESS Encryption 加密模式:${NC}"
    echo "  1. native  - 原始格式包 (头部有公钥特征)"
    echo "  2. xorpub  - 混淆公钥部分"
    echo "  3. random  - 全随机外观 (类似 VMess/SS)"
    read -rp "$(ask "选择 [1-3] (默认: 3): ")" enc_choice
    case ${enc_choice:-3} in
        1) ENC_MODE="native" ;;
        2) ENC_MODE="xorpub" ;;
        *) ENC_MODE="random" ;;
    esac

    read -rp "$(ask "Ticket 复用时间(秒) / 1rtt 禁止复用 (默认: 600s): ")" ticket_time
    ticket_time=${ticket_time:-"600s"}

    DECRYPTION="mlkem768x25519plus.${ENC_MODE}.${ticket_time}.100-111-1111.75-0-111.50-0-3333.${MLKEM_SEED}"

    info "Decryption: ${DECRYPTION:0:80}..."

    PROTO_TYPE="encryption"

    cat > "$XRAY_CONFIG" << JSONEOF
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
      "tag": "vless-in",
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
JSONEOF

    cat > "$XRAY_DIR/.node-info" << METAEOF
TYPE=$PROTO_TYPE
PORT=$PORT
UUID=$UUID
ENC_MODE=$ENC_MODE
TICKET=$ticket_time
DECRYPTION=$DECRYPTION
INSTALL_TIME=$(date '+%Y-%m-%d %H:%M:%S')
METAEOF

    SERVER_IP=$(get_ip)

    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  VLESS + Encryption 服务端配置完成!${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  协议:       ${YELLOW}VLESS + Encryption (PR #5067)${NC}"
    echo -e "  地址:       ${CYAN}$SERVER_IP${NC}"
    echo -e "  端口:       ${CYAN}$PORT${NC}"
    echo -e "  UUID:       ${CYAN}$UUID${NC}"
    echo -e "  加密模式:   ${CYAN}$ENC_MODE${NC}"
    echo -e "  Ticket:     ${CYAN}$ticket_time${NC}"
    echo ""
    echo -e "${YELLOW}⚠ VLESS Encryption 适合 CDN / 中转 / non-TLS${NC}"
    echo -e "${YELLOW}  直接过墙请用 VLESS + REALITY 方案${NC}"
}

#=============================================================================
# VLESS 基础配置
#=============================================================================
config_basic() {
    step "配置 VLESS 基础版"

    PORT=${BASIC_PORT:-$(random_port)}
    read -rp "$(ask "VLESS 端口 (默认: $PORT): ")" input
    PORT=${input:-$PORT}

    UUID=$("$XRAY_BIN" uuid 2>/dev/null)
    [[ -z "$UUID" ]] && error "生成 UUID 失败"

    PROTO_TYPE="basic"

    cat > "$XRAY_CONFIG" << JSONEOF
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
      "tag": "vless-in",
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
JSONEOF

    cat > "$XRAY_DIR/.node-info" << METAEOF
TYPE=$PROTO_TYPE
PORT=$PORT
UUID=$UUID
INSTALL_TIME=$(date '+%Y-%m-%d %H:%M:%S')
METAEOF

    SERVER_IP=$(get_ip)

    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  VLESS 基础版 配置完成!${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  地址:       ${CYAN}$SERVER_IP${NC}"
    echo -e "  端口:       ${CYAN}$PORT${NC}"
    echo -e "  UUID:       ${CYAN}$UUID${NC}"
    echo -e "${YELLOW}⚠ 明文 VLESS 不推荐直接使用${NC}"
}

#=============================================================================
# systemd 服务
#=============================================================================
setup_service() {
    step "配置 systemd 服务"

    cat > /etc/systemd/system/xray.service << 'UNITEOF'
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
UNITEOF

    systemctl daemon-reload
    systemctl enable xray --now 2>/dev/null

    sleep 2
    if systemctl is-active --quiet xray 2>/dev/null; then
        info "Xray 服务运行中 ✓"
    else
        warn "Xray 服务启动失败，检查: systemctl status xray"
        systemctl status xray --no-pager -l 2>/dev/null || true
    fi
}

#=============================================================================
# BBR 优化
#=============================================================================
setup_bbr() {
    step "优化内核参数 (BBR)"

    if lsmod | grep -q tcp_bbr; then
        info "BBR 已启用"
    else
        modprobe tcp_bbr 2>/dev/null || true
        echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || true
    fi

    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$cc" != "bbr" ]]; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
        info "BBR 已设置 ($(sysctl -n net.ipv4.tcp_congestion_control))"
    else
        info "BBR 已启用 ($cc)"
    fi
}

#=============================================================================
# 防火墙
#=============================================================================
setup_firewall() {
    step "配置防火墙"

    local port=$(grep -oP '(?<="port": )\d+' "$XRAY_CONFIG" | head -1)

    # ufw
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "$port"/tcp 2>/dev/null || true
        info "ufw 已放行端口 $port"
    fi

    # firewalld
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="$port"/tcp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        info "firewalld 已放行端口 $port"
    fi

    echo -e "${YELLOW}⚠ 如果 VPS 有外部防火墙（阿里云/腾讯云安全组），请放行端口: $port${NC}"
}

#=============================================================================
# 显示管理命令
#=============================================================================
show_commands() {
    local port=$(grep -oP '(?<="port": )\d+' "$XRAY_CONFIG" | head -1)
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  Xray 管理命令${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  启动/停止/重启: ${GREEN}systemctl start|stop|restart xray${NC}"
    echo -e "  状态:           ${GREEN}systemctl status xray${NC}"
    echo -e "  日志:           ${GREEN}journalctl -u xray -f${NC}"
    echo -e "  重新运行管理:   ${GREEN}bash install.sh --manage${NC}"
    echo -e "  配置文件:       ${GREEN}$XRAY_CONFIG${NC}"
    echo -e "  监听端口:       ${CYAN}$port${NC}"
}

#=============================================================================
# 汇总信息
#=============================================================================
summary() {
    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  安装完成!${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  运行 ${CYAN}bash install.sh --manage${NC} 可管理已搭建的节点"
}

#=============================================================================
# ======================  节点管理模块  ========================
#=============================================================================

# 检测是否已安装
is_installed() {
    [[ -f "$XRAY_BIN" && -f "$XRAY_CONFIG" ]]
}

# 加载节点信息
load_node_info() {
    if [[ -f "$XRAY_DIR/.node-info" ]]; then
        source "$XRAY_DIR/.node-info"
    fi
}

# 显示节点状态
show_status() {
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  节点状态${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    # 服务状态
    if systemctl is-active --quiet xray 2>/dev/null; then
        echo -e "  Xray 服务:  ${GREEN}● 运行中${NC}"
    else
        echo -e "  Xray 服务:  ${RED}● 已停止${NC}"
    fi
    echo -e "  启动时间:   $(systemctl show xray -p ActiveEnterTimestamp 2>/dev/null | cut -d= -f2 || echo '未知')"

    # 节点类型
    load_node_info
    local type_display="未知"
    case ${TYPE:-} in
        reality)    type_display="VLESS + REALITY" ;;
        encryption) type_display="VLESS + Encryption (PR #5067)" ;;
        basic)      type_display="VLESS 基础版" ;;
    esac
    echo -e "  方案类型:   ${YELLOW}$type_display${NC}"

    local port=$(grep -oP '(?<="port": )\d+' "$XRAY_CONFIG" 2>/dev/null | head -1)
    echo -e "  监听端口:   ${CYAN}${port:-未知}${NC}"

    if [[ "$TYPE" == "reality" ]]; then
        echo -e "  伪装 SNI:   ${CYAN}${SNI:-未知}${NC}"
    elif [[ "$TYPE" == "encryption" ]]; then
        echo -e "  加密模式:   ${CYAN}${ENC_MODE:-未知}${NC}"
        echo -e "  Ticket:     ${CYAN}${TICKET:-未知}${NC}"
    fi

    # 连接数
    local conns=$(ss -tnp 2>/dev/null | grep -c ":${port:-0} " || echo "0")
    echo -e "  当前连接:   ${conns}"

    # 流量统计
    if [[ -f /var/log/xray/access.log ]]; then
        local lines=$(wc -l < /var/log/xray/access.log 2>/dev/null || echo "0")
        echo -e "  访问记录:   ${lines} 条"
    fi
}

# 查看配置
view_config() {
    load_node_info
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  节点配置详情${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    SERVER_IP=$(get_ip)
    local port=$(grep -oP '(?<="port": )\d+' "$XRAY_CONFIG" | head -1)
    local uuid=$(grep -oP '(?<="id": ")[^"]+' "$XRAY_CONFIG" | head -1)

    echo -e "  服务器 IP:  ${CYAN}$SERVER_IP${NC}"
    echo -e "  端口:       ${CYAN}$port${NC}"
    echo -e "  UUID:       ${CYAN}$uuid${NC}"

    if [[ "$TYPE" == "reality" ]]; then
        echo -e "  方案:       ${GREEN}VLESS + REALITY${NC}"
        echo -e "  Flow:       ${CYAN}xtls-rprx-vision${NC}"
        echo -e "  PublicKey:  ${CYAN}${PUBLIC_KEY:-}${NC}"
        echo -e "  ShortId:    ${CYAN}${SHORT_ID:-}${NC}"
        echo -e "  SNI:        ${CYAN}${SNI:-}${NC}"
        echo -e "  Fingerprint:${CYAN}chrome${NC}"
        echo -e "  伪装目标:   ${CYAN}${DEST:-}${NC}"

        # 生成分享链接
        local link="vless://${uuid}@${SERVER_IP}:${port}?flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F&type=raw&headerType=none#VLESS-REALITY-$(hostname)"
        echo ""
        echo -e "${BOLD}分享链接:${NC}"
        echo -e "${GREEN}$link${NC}"
        echo "$link" > "$XRAY_DIR/vless-link.txt"

    elif [[ "$TYPE" == "encryption" ]]; then
        echo -e "  方案:       ${GREEN}VLESS + Encryption${NC}"
        echo -e "  加密模式:   ${CYAN}${ENC_MODE:-}${NC}"
        echo -e "  Ticket:     ${CYAN}${TICKET:-}${NC}"

    elif [[ "$TYPE" == "basic" ]]; then
        echo -e "  方案:       ${YELLOW}VLESS 基础版 (明文)${NC}"
    fi

    echo ""
    echo -e "  完整配置: ${GREEN}$XRAY_CONFIG${NC}"
}

# 修改端口
change_port() {
    load_node_info
    local old_port=$(grep -oP '(?<="port": )\d+' "$XRAY_CONFIG" | head -1)
    echo -e "当前端口: ${YELLOW}$old_port${NC}"
    read -rp "$(ask "新端口: ")" new_port
    [[ -z "$new_port" ]] && { info "已取消"; return; }
    [[ ! "$new_port" =~ ^[0-9]+$ ]] && { warn "无效端口号"; return; }

    sed -i "s/\"port\": $old_port/\"port\": $new_port/" "$XRAY_CONFIG"

    # 更新 node-info
    if [[ -f "$XRAY_DIR/.node-info" ]]; then
        sed -i "s/^PORT=.*/PORT=$new_port/" "$XRAY_DIR/.node-info"
    fi

    systemctl restart xray 2>/dev/null
    sleep 1

    # 防火墙更新
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw delete allow "$old_port"/tcp 2>/dev/null || true
        ufw allow "$new_port"/tcp 2>/dev/null || true
    fi

    if systemctl is-active --quiet xray 2>/dev/null; then
        info "端口已改为 ${GREEN}$new_port${NC}，服务运行中 ✓"
        echo -e "${YELLOW}⚠ 记得更新云防火墙安全组规则!${NC}"
    else
        warn "服务启动失败，检查: systemctl status xray"
    fi
}

# 查看实时日志
view_logs() {
    echo -e "${YELLOW}实时日志 (Ctrl+C 退出)...${NC}"
    journalctl -u xray -f --no-pager -n 50
}

# 管理菜单主循环
manage_menu() {
    if ! is_installed; then
        warn "未检测到已安装的 Xray 节点"
        echo -e "  请先运行: ${CYAN}bash install.sh${NC}"
        exit 1
    fi

    while true; do
        echo ""
        echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${BLUE}║     Xray 节点管理                                       ║${NC}"
        echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "  1. 查看节点状态"
        echo "  2. 查看完整配置 & 分享链接"
        echo "  3. 重启 Xray 服务"
        echo "  4. 停止 Xray 服务"
        echo "  5. 启动 Xray 服务"
        echo "  6. 查看实时日志"
        echo "  7. 修改监听端口"
        echo "  8. 更新 Xray 核心"
        echo "  0. 退出"
        echo ""
        read -rp "$(ask "请选择 [0-8]: ")" choice

        case $choice in
            1) show_status ;;
            2) view_config ;;
            3)
                systemctl restart xray 2>/dev/null
                sleep 1
                if systemctl is-active --quiet xray; then
                    info "Xray 已重启 ✓"
                else
                    warn "重启失败，查看: journalctl -u xray -n 20"
                fi
                ;;
            4)
                systemctl stop xray 2>/dev/null
                info "Xray 已停止"
                ;;
            5)
                systemctl start xray 2>/dev/null
                sleep 1
                if systemctl is-active --quiet xray; then
                    info "Xray 已启动 ✓"
                else
                    warn "启动失败"
                fi
                ;;
            6) view_logs ;;
            7) change_port ;;
            8)
                echo -e "${CYAN}重新安装 Xray 最新版...${NC}"
                install_xray
                systemctl restart xray 2>/dev/null
                if systemctl is-active --quiet xray; then
                    info "Xray 已更新到最新版 ✓"
                fi
                ;;
            0) echo "退出管理"; exit 0 ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac
    done
}

#=============================================================================
# 主菜单
#=============================================================================
main_menu() {
    clear
    echo -e "${BOLD}${BLUE}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║     Xray VLESS 一键安装 & 管理脚本                  ║"
    echo "║     支持: REALITY | Encryption(PR#5067) | 基础版    ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # 检查是否已安装
    if is_installed; then
        echo -e "${YELLOW}  检测到已安装的节点!${NC}"
        load_node_info
        local port=$(grep -oP '(?<="port": )\d+' "$XRAY_CONFIG" | head -1)
        local type_display="未知"
        case ${TYPE:-} in
            reality) type_display="VLESS + REALITY" ;;
            encryption) type_display="VLESS + Encryption" ;;
            basic) type_display="VLESS 基础版" ;;
        esac
        echo -e "  当前方案: ${GREEN}$type_display${NC}  端口: ${CYAN}${port:-?}${NC}"
        echo ""
        echo "  1. 管理已有节点"
        echo "  2. 重新安装 (覆盖当前配置)"
        echo "  3. 退出"
        echo ""
        read -rp "$(ask "请选择 [1-3]: ")" choice
        case $choice in
            1) manage_menu; exit 0 ;;
            2) info "将覆盖现有配置，重新安装..."
               systemctl stop xray 2>/dev/null || true
               ;;
            3) exit 0 ;;
            *) error "无效选择" ;;
        esac
    fi

    echo ""
    echo "  1. VLESS + REALITY    (推荐 - 直接过墙, 伪装流量)"
    echo "  2. VLESS + Encryption (PR #5067 - 后量子加密, CDN/中转)"
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
# 入口
#=============================================================================
main() {
    # 检查是否要求进入管理模式
    if [[ "$1" == "--manage" || "$1" == "-m" ]]; then
        if ! is_installed; then
            error "未检测到已安装的节点，请先运行 bash install.sh"
        fi
        manage_menu
        exit 0
    fi

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
