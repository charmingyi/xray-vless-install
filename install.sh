#!/bin/bash
#=============================================================================
# Xray VLESS 一键安装 & 管理脚本
# 支持: REALITY | Encryption (PR #5067 / xray vlessenc) | 基础版
# 架构参照 Xray vlessenc 官方命令 + 多节点共存
# Repo: https://github.com/charmingyi/xray-vless-install
#=============================================================================
set -euo pipefail

# --- 颜色 ---
readonly RED='\e[91m' GREEN='\e[92m' YELLOW='\e[93m'
readonly CYAN='\e[96m' MAGENTA='\e[95m' NC='\e[0m'
readonly BOLD='\e[1m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}==>${NC}${BOLD} $*${NC}"; }
success() { echo -e "${GREEN}[OK]${NC}  $*"; }
ask()     { echo -ne "${CYAN}[?]${NC} $* "; }

# BusyBox/Alpine 兼容：不要依赖 GNU grep -P
kv_get() { awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$2" 2>/dev/null || true; }
extract_after_colon() { awk -F': *' -v k="$1" '$1==k {print $2; exit}'; }
extract_xray_key() {
    local want="$1"
    awk -F': *' -v want="$want" '
        { key=tolower($1); gsub(/[[:space:]_-]/, "", key) }
        want=="private" && (key=="privatekey" || key=="private") { print $2; exit }
        want=="public" && (key=="publickey" || key=="public" || key=="password") { print $2; exit }
    '
}
extract_json_string_last() {
    local key="$1"
    awk -v key="$key" '{
        pattern="\\\"" key "\\\"[[:space:]]*:[[:space:]]*\\\""
        if (match($0, pattern)) {
            s=substr($0, RSTART+RLENGTH)
            sub(/".*/, "", s)
            v=s
        }
    } END { if (v != "") print v }'
}

# --- 路径 ---
readonly XRAY_DIR="/usr/local/etc/xray"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONFIG="$XRAY_DIR/config.json"
readonly XRAY_LOG="/var/log/xray"
readonly NODE_INFO="$XRAY_DIR/.node-info"

# --- 兼容旧版 key=value 格式 .node-info ---
load_node_json() {
    if [[ ! -f "$NODE_INFO" ]]; then echo '{}'; return; fi
    if jq -e . "$NODE_INFO" &>/dev/null; then
        cat "$NODE_INFO"
    else
        # 旧格式: TYPE=reality PORT=443 UUID=xxx ...
        local t=$(kv_get TYPE "$NODE_INFO"); t=${t:-?}
        local p=$(kv_get PORT "$NODE_INFO"); p=${p:-?}
        local u=$(kv_get UUID "$NODE_INFO"); u=${u:-?}
        local sni=$(kv_get SNI "$NODE_INFO")
        local pbk=$(kv_get PUBLIC_KEY "$NODE_INFO")
        local sid=$(kv_get SHORT_ID "$NODE_INFO")
        local enc=$(kv_get ENC_KEY "$NODE_INFO")
        jq -n --arg t "$t" --arg p "$p" --arg u "$u" --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg enc "$enc" \
          '{type: $t, port: $p, uuid: $u, sni: $sni, pbk: $pbk, sid: $sid, encryption: $enc}'
    fi
}

#=============================================================================
# 工具
#=============================================================================
random_hex() { openssl rand -hex "${1:-8}" 2>/dev/null || head -c "$(( ${1:-8} * 2 ))" /dev/urandom | xxd -p; }
random_port() { echo $(( RANDOM % 30000 + 10000 )); }
is_valid_port() { [[ "$1" =~ ^[0-9]+$ && "$1" -ge 1 && "$1" -le 65535 ]]; }
is_valid_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }

get_ip() {
    for u in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
        local ip=$(curl -4s --max-time 5 "$u" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
    done
    echo "YOUR_IP"
}

#=============================================================================
# 系统检测
#=============================================================================
detect_system() {
    if [[ -f /etc/os-release ]]; then . /etc/os-release; else OS_ID="unknown"; fi
    if command -v systemctl &>/dev/null; then INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then INIT_SYSTEM="openrc"
    else INIT_SYSTEM="unknown"; fi
}

pre_check() {
    [[ $(id -u) != 0 ]] && error "请用 root 运行"
    [[ $(uname -s) != "Linux" ]] && error "仅支持 Linux"
    local m=$(uname -m)
    [[ "$m" != "x86_64" && "$m" != "aarch64" && "$m" != "amd64" ]] && error "仅支持 x86_64 / arm64"
    detect_system
    # 解析逻辑已避免 grep -P，兼容 Alpine BusyBox
    info "系统: ${PRETTY_NAME:-$OS_ID} | 架构: $(uname -m) | 服务: $INIT_SYSTEM"
}

#=============================================================================
# 依赖安装 (Debian: .deb 直下 / Alpine: apk)
#=============================================================================
install_deps() {
    step "安装基础依赖"

    # ---- Alpine ----
    if command -v apk &>/dev/null; then
        apk add --no-cache curl wget unzip jq openssl 2>/dev/null || true
        for c in curl wget unzip jq openssl; do
            command -v "$c" &>/dev/null || error "无法安装 $c"
        done
        success "依赖就绪 (apk)"
        return
    fi

    # ---- Debian/Ubuntu ----
    local missing=""
    for c in curl wget unzip jq libjq1 openssl; do
        command -v "$c" &>/dev/null || missing="$missing $c"
    done
    [[ -z "$missing" ]] && { info "所有依赖已就绪"; return; }
    info "缺少:${missing}"

    local arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    for pkg in $missing; do
        local url=""
        url=$(apt-cache show "$pkg" 2>/dev/null | grep "^Filename:" | head -1 | awk -v base="http://deb.debian.org/debian" '{print base"/"$2}')
        [[ -z "$url" ]] && url=$(apt-get install --print-uris -y "$pkg" 2>/dev/null | grep "^'" | head -1 | cut -d"'" -f2)
        [[ -z "$url" ]] && case $pkg in
            curl)  url="http://deb.debian.org/debian/pool/main/c/curl/curl_*_${arch}.deb" ;;
            wget)  url="http://deb.debian.org/debian/pool/main/w/wget/wget_*_${arch}.deb" ;;
            unzip) url="http://deb.debian.org/debian/pool/main/u/unzip/unzip_*_${arch}.deb" ;;
            jq|libjq1) url="http://deb.debian.org/debian/pool/main/j/jq/jq_*_${arch}.deb" ;;
            openssl) url="http://deb.debian.org/debian/pool/main/o/openssl/openssl_*_${arch}.deb" ;;
        esac

        echo -ne "  ${CYAN}下载 $pkg...${NC}"
        if curl -fsSL --connect-timeout 10 --retry 2 "$url" -o "/tmp/${pkg}.deb" 2>/dev/null; then
            dpkg -i "/tmp/${pkg}.deb" &>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAIL${NC}"
            rm -f "/tmp/${pkg}.deb"
        else
            echo -e " ${YELLOW}直下失败, apt兜底${NC}"
            timeout 30 apt-get install -y --no-install-recommends "$pkg" 2>/dev/null || true
        fi
    done
    timeout 30 apt-get install -f -y --no-install-recommends 2>/dev/null || true

    for c in curl wget unzip jq openssl; do
        command -v "$c" &>/dev/null || error "无法安装 $c，请手动安装"
    done
    success "依赖就绪"
}

#=============================================================================
# Xray 核心安装
#=============================================================================
install_xray() {
    step "安装 Xray-core"

    # 停旧服务避免 Text file busy
    if [[ "$INIT_SYSTEM" == "systemd" ]] && systemctl is-active --quiet xray 2>/dev/null; then
        systemctl stop xray; info "已停止旧服务"
    fi
    pkill -f "$XRAY_BIN" 2>/dev/null || true; sleep 1

    local arch; case $(uname -m) in x86_64|amd64) arch="64";; aarch64|arm64) arch="arm64-v8a";; esac

    # 版本: 先试 API 再 fallback
    local tag; tag=$(curl -sL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
        | jq -r '.tag_name//empty' 2>/dev/null)
    [[ -z "$tag" || "$tag" == "null" ]] && tag="v26.3.27"
    info "版本: $tag"

    local tmpd=$(mktemp -d)
    curl -#L "https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${arch}.zip" -o "$tmpd/xray.zip" || error "下载失败"
    unzip -qo "$tmpd/xray.zip" -d "$tmpd"
    install -m 0755 "$tmpd/xray" "$XRAY_BIN"
    mkdir -p "$XRAY_DIR" /usr/local/share/xray "$XRAY_LOG"
    cp "$tmpd/geoip.dat" "$tmpd/geosite.dat" /usr/local/share/xray/ 2>/dev/null || true
    rm -rf "$tmpd"
    success "Xray $tag 已安装"
}

#=============================================================================
# GeoData (Loyalsoldier 版，更全)
#=============================================================================
install_geodata() {
    step "更新 GeoData"
    curl -fsSL -o /usr/local/share/xray/geoip.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    curl -fsSL -o /usr/local/share/xray/geosite.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
    success "GeoData 已更新"
}

#=============================================================================
# 服务安装
#=============================================================================
setup_service() {
    step "配置服务"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        cat > /etc/systemd/system/xray.service << 'UEOF'
[Unit]
Description=Xray Service
After=network-online.target
Wants=network-online.target

[Service]
User=root
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=false
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UEOF
        systemctl daemon-reload; systemctl enable --now xray
    else
        cat > /etc/init.d/xray << 'IEOF'
#!/sbin/openrc-run
name="xray"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
start_stop_daemon_args="--make-pidfile --background --stdout /var/log/xray/xray.log --stderr /var/log/xray/xray.log"
depend() { need net; use dns; }
IEOF
        mkdir -p /var/log/xray
        chmod +x /etc/init.d/xray; rc-update add xray default; rc-service xray restart || rc-service xray start
    fi
    sleep 2
    success "服务已启动"
}

#=============================================================================
# REALITY 配置
#=============================================================================
config_reality() {
    step "配置 VLESS + REALITY"

    local port=${1:-$(random_port)}
    read -rp "$(ask "端口 (默认 $port): ")" i; port=${i:-$port}
    is_valid_port "$port" || error "无效端口"
    [[ "$port" != "443" ]] && warn "REALITY 正在使用非 443 端口；NAT 小鸡可用，但客户端必须填写 NAT 外部映射端口，云面板也必须放行该 TCP 端口"

    local keys; keys=$("$XRAY_BIN" x25519 2>/dev/null)
    local pk; pk=$(echo "$keys" | extract_xray_key "private")
    local pbk; pbk=$(echo "$keys" | extract_xray_key "public")
    [[ -z "$pk" || -z "$pbk" ]] && error "REALITY 密钥生成失败"

    local uuid; uuid=$("$XRAY_BIN" uuid 2>/dev/null)
    local sid; sid=$(random_hex 8); local sid2; sid2=$(random_hex 8)

    echo ""
    echo "  REALITY 伪装站点:"
    echo "    1. www.microsoft.com  2. www.apple.com"
    echo "    3. www.amazon.com     4. cloudflare.com  5. 自定义"
    read -rp "$(ask "选择 [1-5] (默认 1): ")" dc
    local dest sni; case ${dc:-1} in
        1) dest="www.microsoft.com:443"; sni="www.microsoft.com";;
        2) dest="www.apple.com:443"; sni="www.apple.com";;
        3) dest="www.amazon.com:443"; sni="www.amazon.com";;
        4) dest="cloudflare.com:443"; sni="cloudflare.com";;
        5) read -rp "$(ask "目标 (host:port): ")" dest; sni="${dest%:*}";;
        *) dest="www.microsoft.com:443"; sni="www.microsoft.com";;
    esac

    local ip; ip=$(get_ip)

    # 写服务端配置
    jq -n --argjson port "$port" --arg uuid "$uuid" --arg priv "$pk" \
          --arg dest "$dest" --arg sni "$sni" --arg sid "$sid" --arg sid2 "$sid2" --arg ip "$ip" \
    '{
      log: { loglevel: "warning", access: "/var/log/xray/access.log", error: "/var/log/xray/error.log" },
      inbounds: [{
        port: $port, protocol: "vless", tag: "vless-reality-in",
        settings: {
          clients: [{ id: $uuid, flow: "xtls-rprx-vision" }],
          decryption: "none"
        },
        streamSettings: {
          network: "tcp", security: "reality",
          realitySettings: {
            show: false, dest: $dest, xver: 0,
            serverNames: [$sni], privateKey: $priv,
            shortIds: [$sid, $sid2]
          }
        }
      }],
      outbounds: [{ protocol: "freedom", tag: "direct" }, { protocol: "blackhole", tag: "blocked" }]
    }' > "$XRAY_CONFIG"

    # 元信息
    jq -n --arg type "reality" --argjson port "$port" --arg uuid "$uuid" \
          --arg sni "$sni" --arg pbk "$pbk" --arg pk "$pk" --arg sid "$sid" \
          --arg dest "$dest" --arg ip "$ip" --arg time "$(date '+%Y-%m-%d %H:%M:%S')" \
    '{
      type: $type, port: $port, uuid: $uuid, sni: $sni,
      pbk: $pbk, pk: $pk, sid: $sid, dest: $dest,
      ip: $ip, time: $time
    }' > "$NODE_INFO"

    # 分享链接
    local link="vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&spx=%2F&type=tcp&headerType=none#REALITY-${sni}"
    echo "$link" > "$XRAY_DIR/vless-link.txt"

    echo ""
    echo -e "${GREEN}════════════════════ VLESS + REALITY ════════════════════${NC}"
    echo -e "  地址:   ${CYAN}$ip${NC}          端口: ${CYAN}$port${NC}"
    echo -e "  UUID:   ${CYAN}$uuid${NC}"
    echo -e "  公钥:   ${CYAN}$pbk${NC}     ShortId: ${CYAN}$sid${NC}"
    echo -e "  伪装:   ${CYAN}$sni${NC}    指纹: chrome"
    echo ""
    echo -e "${BOLD}分享链接:${NC}"
    echo -e "${GREEN}$link${NC}"
}

#=============================================================================
# VLESS Encryption 配置 (xray vlessenc)
#=============================================================================
config_encryption() {
    step "配置 VLESS + Encryption"

    local port=${1:-$(random_port)}
    read -rp "$(ask "端口 (默认 $port): ")" i; port=${i:-$port}

    local uuid; uuid=$("$XRAY_BIN" uuid 2>/dev/null)

    # 用 xray vlessenc 生成密钥对
    local out dec enc
    out=$("$XRAY_BIN" vlessenc 2>/dev/null || true)

    # 提取 decryption（服务端用）和 encryption（客户端分享链接用）
    # vlessenc 会输出 X25519 和 ML-KEM-768 两套，取最后一套（后量子）
    dec=$(echo "$out" | extract_json_string_last "decryption")
    enc=$(echo "$out" | extract_json_string_last "encryption")

    if [[ -z "$dec" || -z "$enc" ]]; then
        # vlessenc 不可用，用 mlkem768 直出长密钥
        warn "vlessenc 失败，用 mlkem768 直出密钥..."
        local mlkem_out; mlkem_out=$("$XRAY_BIN" mlkem768 2>/dev/null)
        local seed client
        seed=$(echo "$mlkem_out" | extract_after_colon "Seed")
        client=$(echo "$mlkem_out" | extract_after_colon "Client")
        [[ -z "$seed" ]] && error "mlkem768 密钥生成失败"
        dec="mlkem768x25519plus.random.600s.100-111-1111.75-0-111.50-0-3333.${seed}"
        enc="mlkem768x25519plus.random.600s.100-111-1111.75-0-111.50-0-3333.${client}"
    fi

    # native -> random
    dec="${dec/.native./.random.}"
    enc="${enc/.native./.random.}"

    local ip; ip=$(get_ip)

    # 追加 inbounds 配置（兼容已有节点）
    local cfg new_inbound
    if [[ -f "$XRAY_CONFIG" ]]; then
        cfg=$(cat "$XRAY_CONFIG")
    else
        cfg='{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"blocked"}]}'
    fi

    new_inbound=$(jq -n --argjson port "$port" --arg uuid "$uuid" --arg dec "$dec" --arg enc "$enc" \
    '{
      port: $port, protocol: "vless", tag: "vless-pq-in-\($port)",
      settings: {
        clients: [{ id: $uuid }],
        decryption: $dec,
        encryption: $enc,
        selectedAuth: "ML-KEM-768, Post-Quantum"
      },
      streamSettings: { network: "tcp" }
    }')

    echo "$cfg" | jq --argjson new "$new_inbound" \
        'if .inbounds == null then .inbounds = [] else . end | .inbounds += [$new]' > "$XRAY_CONFIG"

    # 元信息
    jq -n --arg type "encryption" --argjson port "$port" --arg uuid "$uuid" \
          --arg enc "$enc" --arg dec "$dec" --arg ip "$ip" --arg time "$(date '+%Y-%m-%d %H:%M:%S')" \
    '{
      type: $type, port: $port, uuid: $uuid,
      encryption: $enc, decryption: $dec,
      ip: $ip, time: $time
    }' > "$NODE_INFO"

    # 分享链接
    local disp=$ip; [[ "$ip" =~ ":" ]] && disp="[$ip]"
    local link="vless://${uuid}@${disp}:${port}?encryption=${enc}&type=tcp&security=none#VLESS-PQ-${port}"
    echo "$link" > "$XRAY_DIR/vless-link.txt"

    echo ""
    echo -e "${GREEN}════════════ VLESS + Encryption (PQ) ════════════${NC}"
    echo -e "  地址:   ${CYAN}$ip${NC}          端口: ${CYAN}$port${NC}"
    echo -e "  UUID:   ${CYAN}$uuid${NC}"
    echo ""
    echo -e "${BOLD}分享链接 (可直接导入):${NC}"
    echo -e "${GREEN}$link${NC}"
}

#=============================================================================
# REALITY + Encryption 双层 (防探测 + 后量子加密)
#=============================================================================
config_reality_encryption() {
    step "配置 REALITY + VLESS Encryption (双层)"

    local port=${1:-443}
    read -rp "$(ask "端口 (默认 $port): ")" i; port=${i:-$port}
    is_valid_port "$port" || error "无效端口"

    # REALITY 密钥对
    local keys; keys=$("$XRAY_BIN" x25519 2>/dev/null)
    local pk; pk=$(echo "$keys" | extract_xray_key "private")
    local pbk; pbk=$(echo "$keys" | extract_xray_key "public")
    [[ -z "$pk" || -z "$pbk" ]] && error "REALITY 密钥生成失败"

    # VLESS Encryption 密钥对 (ML-KEM-768)
    local out dec enc
    out=$("$XRAY_BIN" vlessenc 2>/dev/null || true)
    dec=$(echo "$out" | extract_json_string_last "decryption")
    enc=$(echo "$out" | extract_json_string_last "encryption")
    [[ -z "$dec" || -z "$enc" ]] && error "vlessenc 密钥生成失败"
    dec="${dec/.native./.random.}"
    enc="${enc/.native./.random.}"

    local uuid; uuid=$("$XRAY_BIN" uuid 2>/dev/null)
    local sid; sid=$(random_hex 8)

    echo ""
    echo "  REALITY 伪装站点:"
    echo "    1. www.microsoft.com  2. www.apple.com"
    echo "    3. www.amazon.com     4. cloudflare.com  5. 自定义"
    read -rp "$(ask "选择 [1-5] (默认 1): ")" dc
    local dest sni; case ${dc:-1} in
        1) dest="www.microsoft.com:443"; sni="www.microsoft.com";;
        2) dest="www.apple.com:443"; sni="www.apple.com";;
        3) dest="www.amazon.com:443"; sni="www.amazon.com";;
        4) dest="cloudflare.com:443"; sni="cloudflare.com";;
        5) read -rp "$(ask "目标 (host:port): ")" dest; sni="${dest%:*}";;
        *) dest="www.microsoft.com:443"; sni="www.microsoft.com";;
    esac

    local ip; ip=$(get_ip)

    # 追加 inbounds (兼容已有节点)
    local cfg new_inbound
    if [[ -f "$XRAY_CONFIG" ]]; then
        cfg=$(cat "$XRAY_CONFIG")
    else
        cfg='{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"blocked"}]}'
    fi

    new_inbound=$(jq -n --argjson port "$port" --arg uuid "$uuid" \
        --arg dec "$dec" --arg enc "$enc" --arg priv "$pk" \
        --arg dest "$dest" --arg sni "$sni" --arg sid "$sid" \
    '{
      port: $port, protocol: "vless", tag: "vless-pq-real-in-\($port)",
      settings: {
        clients: [{ id: $uuid }],
        decryption: $dec,
        encryption: $enc,
        selectedAuth: "ML-KEM-768, Post-Quantum"
      },
      streamSettings: {
        network: "tcp",
        security: "reality",
        realitySettings: {
          show: false, dest: $dest, xver: 0,
          serverNames: [$sni], privateKey: $priv,
          shortIds: [$sid]
        }
      }
    }')

    echo "$cfg" | jq --argjson new "$new_inbound" \
        'if .inbounds == null then .inbounds = [] else . end | .inbounds += [$new]' > "$XRAY_CONFIG"

    # 元信息
    jq -n --arg type "reality-enc" --argjson port "$port" --arg uuid "$uuid" \
          --arg sni "$sni" --arg pbk "$pbk" --arg pk "$pk" --arg sid "$sid" \
          --arg dest "$dest" --arg enc "$enc" --arg dec "$dec" \
          --arg ip "$ip" --arg time "$(date '+%Y-%m-%d %H:%M:%S')" \
    '{
      type: $type, port: $port, uuid: $uuid, sni: $sni,
      pbk: $pbk, pk: $pk, sid: $sid, dest: $dest,
      encryption: $enc, decryption: $dec,
      ip: $ip, time: $time
    }' > "$NODE_INFO"

    # 分享链接 (REALITY + PQ)
    local disp=$ip; [[ "$ip" =~ ":" ]] && disp="[$ip]"
    local link="vless://${uuid}@${disp}:${port}?encryption=${enc}&security=reality&sni=${sni}&pbk=${pbk}&sid=${sid}&fp=chrome&type=tcp&headerType=none#VLESS-PQ-REALITY-${port}"
    echo "$link" > "$XRAY_DIR/vless-link.txt"

    echo ""
    echo -e "${GREEN}══════════ REALITY + Encryption (双层) ══════════${NC}"
    echo -e "  地址:   ${CYAN}$ip${NC}          端口: ${CYAN}$port${NC}"
    echo -e "  UUID:   ${CYAN}$uuid${NC}"
    echo -e "  伪装:   ${CYAN}$sni${NC}    指纹: chrome"
    echo -e "  REALITY公钥: ${CYAN}$pbk${NC}"
    echo -e "  PQ加密: ${CYAN}ML-KEM-768${NC} (${#enc} chars)"
    echo ""
    echo -e "${BOLD}分享链接 (可直接导入):${NC}"
    echo -e "${GREEN}$link${NC}"
}

#=============================================================================
# VLESS 基础版
#=============================================================================
config_basic() {
    step "配置 VLESS 基础版"

    local port=${1:-$(random_port)}
    read -rp "$(ask "端口 (默认 $port): ")" i; port=${i:-$port}

    local uuid; uuid=$("$XRAY_BIN" uuid 2>/dev/null)
    local ip; ip=$(get_ip)

    local cfg new_inbound
    if [[ -f "$XRAY_CONFIG" ]]; then cfg=$(cat "$XRAY_CONFIG")
    else cfg='{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"blocked"}]}'; fi

    new_inbound=$(jq -n --argjson port "$port" --arg uuid "$uuid" \
    '{
      port: $port, protocol: "vless", tag: "vless-basic-in-\($port)",
      settings: { clients: [{ id: $uuid }], decryption: "none" },
      streamSettings: { network: "tcp" }
    }')

    echo "$cfg" | jq --argjson new "$new_inbound" \
        'if .inbounds == null then .inbounds = [] else . end | .inbounds += [$new]' > "$XRAY_CONFIG"

    jq -n --arg type "basic" --argjson port "$port" --arg uuid "$uuid" \
          --arg ip "$ip" --arg time "$(date '+%Y-%m-%d %H:%M:%S')" \
    '{ type: $type, port: $port, uuid: $uuid, ip: $ip, time: $time }' > "$NODE_INFO"

    local link="vless://${uuid}@${ip}:${port}?encryption=none&type=tcp&security=none#VLESS-Basic-${port}"
    echo "$link" > "$XRAY_DIR/vless-link.txt"

    echo -e "${GREEN}VLESS 基础版已配置${NC}  端口: $port  UUID: $uuid"
    echo -e "${GREEN}$link${NC}"
}

#=============================================================================
# 防火墙 & BBR
#=============================================================================
setup_firewall() {
    local ports; ports=$(jq -r '[.inbounds[].port] | unique | .[]' "$XRAY_CONFIG" 2>/dev/null)
    [[ -z "$ports" ]] && return
    for p in $ports; do
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q active; then
            ufw allow "$p"/tcp 2>/dev/null || true
        elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall-cmd --permanent --add-port="$p"/tcp 2>/dev/null || true
        elif command -v iptables &>/dev/null; then
            iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
        fi
    done
    command -v firewall-cmd &>/dev/null && firewall-cmd --reload 2>/dev/null || true
    info "防火墙已放行端口: $(echo $ports | tr '\n' ' ')"
    echo -e "${YELLOW}⚠ 云防火墙安全组也需放行相同端口${NC}"
}

setup_bbr() {
    # Alpine: 跳过（内核通常不含 BBR 模块）
    command -v apk &>/dev/null && { warn "Alpine 跳过 BBR"; return; }
    lsmod | grep -q tcp_bbr && return
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || true
    grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf || {
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    }
    info "BBR 已启用"
}

#=============================================================================
# 管理菜单
#=============================================================================
view_config() {
    local info; info=$(load_node_json) || { warn "无节点信息"; return; }
    local type; type=$(echo "$info" | jq -r '.type//empty')
    local port; port=$(echo "$info" | jq -r '.port//empty')
    local uuid; uuid=$(echo "$info" | jq -r '.uuid//empty')
    local ip; ip=$(get_ip)

    echo -e "\n${BOLD}═══ 节点配置 ═══${NC}"
    echo -e "  类型: ${GREEN}$type${NC}    端口: ${CYAN}$port${NC}"
    echo -e "  地址: ${CYAN}$ip${NC}    UUID: ${CYAN}$uuid${NC}"

    if [[ "$type" == "reality" ]]; then
        local sni pbk sid
        sni=$(echo "$info" | jq -r '.sni//empty')
        pbk=$(echo "$info" | jq -r '.pbk//empty')
        sid=$(echo "$info" | jq -r '.sid//empty')
        echo -e "  SNI: ${CYAN}$sni${NC}    公钥: ${CYAN}$pbk${NC}"
        echo -e "  ShortId: ${CYAN}$sid${NC}"
        local link="vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&spx=%2F&type=tcp&headerType=none#REALITY-${sni}"
        echo -e "\n${BOLD}分享链接:${NC}\n${GREEN}$link${NC}"
        echo "$link" > "$XRAY_DIR/vless-link.txt"
    elif [[ "$type" == "encryption" ]]; then
        local enc; enc=$(echo "$info" | jq -r '.encryption//empty')
        local disp=$ip; [[ "$ip" =~ ":" ]] && disp="[$ip]"
        local link="vless://${uuid}@${disp}:${port}?encryption=${enc}&type=tcp&security=none#VLESS-PQ-${port}"
        echo -e "\n${BOLD}分享链接:${NC}\n${GREEN}$link${NC}"
        echo "$link" > "$XRAY_DIR/vless-link.txt"
    elif [[ "$type" == "reality-enc" ]]; then
        local sni pbk sid enc
        sni=$(echo "$info" | jq -r '.sni//empty')
        pbk=$(echo "$info" | jq -r '.pbk//empty')
        sid=$(echo "$info" | jq -r '.sid//empty')
        enc=$(echo "$info" | jq -r '.encryption//empty')
        echo -e "  SNI: ${CYAN}$sni${NC}    公钥: ${CYAN}$pbk${NC}"
        echo -e "  ShortId: ${CYAN}$sid${NC}    PQ: ${CYAN}$(echo "$enc" | wc -c) chars${NC}"
        local disp=$ip; [[ "$ip" =~ ":" ]] && disp="[$ip]"
        local link="vless://${uuid}@${disp}:${port}?encryption=${enc}&security=reality&sni=${sni}&pbk=${pbk}&sid=${sid}&fp=chrome&type=tcp&headerType=none#VLESS-PQ-REALITY-${port}"
        echo -e "\n${BOLD}分享链接:${NC}\n${GREEN}$link${NC}"
        echo "$link" > "$XRAY_DIR/vless-link.txt"
    elif [[ "$type" == "basic" ]]; then
        local link="vless://${uuid}@${ip}:${port}?encryption=none&type=tcp&security=none#VLESS-Basic-${port}"
        echo -e "\n${BOLD}分享链接:${NC}\n${GREEN}$link${NC}"
        echo "$link" > "$XRAY_DIR/vless-link.txt"
    fi
}

show_status() {
    echo -e "\n${BOLD}═══ 运行状态 ═══${NC}"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl is-active --quiet xray && echo -e "  Xray: ${GREEN}● 运行中${NC}" || echo -e "  Xray: ${RED}● 已停止${NC}"
    else
        rc-service xray status 2>/dev/null | grep -qi started && echo -e "  Xray: ${GREEN}● 运行中${NC}" || echo -e "  Xray: ${RED}● 已停止${NC}"
    fi
    echo -e "  版本: $("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}' || echo '?')"

    local ports; ports=$(jq -r '[.inbounds[].port] | unique | .[]' "$XRAY_CONFIG" 2>/dev/null)
    for p in $ports; do
        local conns=$(ss -tnp 2>/dev/null | grep -c ":$p " || echo 0)
        echo -e "  端口 $p: ${conns} 连接"
    done
}

restart_svc() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl restart xray; else rc-service xray restart; fi
    sleep 1
    info "Xray 已重启"
}

#=============================================================================
# 主菜单 (mack-a 风格)
#=============================================================================
SCRIPT_VER="2.0.0"

show_header() {
    clear
    local xver; xver=$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}' || echo "未安装")
    local svc="未运行"
    if [[ "$INIT_SYSTEM" == "systemd" ]] && systemctl is-active --quiet xray 2>/dev/null; then svc="运行中"
    elif [[ "$INIT_SYSTEM" == "openrc" ]] && rc-service xray status 2>/dev/null | grep -qi started; then svc="运行中"
    fi

    echo -e "${BOLD}${CYAN}"
    echo "=============================================================="
    echo -e "  作者: JJQQA / David Tao           版本: ${SCRIPT_VER}"
    echo "  Github: https://github.com/charmingyi/xray-vless-install"
    echo "  描述: VLESS REALITY / Encryption(PQ) 一键管理"
    echo "=============================================================="
    echo -e "${NC}"
    echo -e "  Xray: ${GREEN}${xver}${NC}    状态: ${GREEN}${svc}${NC}"

    # 已安装节点列表
    if [[ -f "$XRAY_CONFIG" ]]; then
        jq -r '.inbounds[] | "  [\(.protocol | ascii_upcase)] 端口:\(.port)  \(.tag)"' "$XRAY_CONFIG" 2>/dev/null
    else
        echo -e "  ${YELLOW}尚未安装任何节点${NC}"
    fi
    echo "=============================================================="
}

show_separator() {
    echo "-------------------------${1:-}-----------------------------"
}

main_menu() {
    while true; do
        show_header
        echo ""
        local has=false; [[ -f "$XRAY_BIN" && -f "$XRAY_CONFIG" ]] && has=true

        if ! $has; then
            echo "  1. 安装 VLESS + REALITY"
            echo "  2. 安装 VLESS + Encryption (PQ)"
            echo "  3. 安装 VLESS 基础版"
            echo "  4. 安装 REALITY + Encryption (双层)"
            echo "  0. 退出"
            echo ""
            read -rp "  请选择 [0-4]: " c
            case $c in
                1) config_reality; setup_firewall; setup_service; setup_bbr;;
                2) config_encryption; setup_firewall; setup_service; setup_bbr;;
                3) config_basic; setup_firewall; setup_service; setup_bbr;;
                4) config_reality_encryption; setup_firewall; setup_service; setup_bbr;;
                0) exit 0;;
                *) echo "无效"; sleep 1;;
            esac
            continue
        fi

        # === 已安装菜单 ===
        echo "  1. 新增 REALITY 节点"
        echo "  2. 新增 Encryption 节点"
        echo "  3. 新增 基础版 节点"
        echo "  4. 新增 REALITY + Encryption (双层)"
        echo ""
        show_separator "节点管理"
        echo "  5. 查看状态 & 连接数"
        echo "  6. 查看/导出 分享链接"
        echo "  7. 删除节点"
        echo "  8. 重置 REALITY 密钥"
        echo "  9. 重启 Xray"
        echo "  10. 停止/启动"
        echo "  11. 实时日志"
        echo ""
        show_separator "工具"
        echo "  12. 更新 Xray 核心"
        echo "  13. 创建快捷命令 xr"
        echo "  0. 退出"
        echo ""
        read -rp "  请选择 [0-13]: " c
        case $c in
            1) config_reality; setup_firewall; restart_svc;;
            2) config_encryption; setup_firewall; restart_svc;;
            3) config_basic; setup_firewall; restart_svc;;
            4) config_reality_encryption; setup_firewall; restart_svc;;
            5) show_status; press_key;;
            6) view_config; press_key;;
            7) delete_node;;
            8) regen_reality_keys;;
            9) restart_svc; press_key;;
            10) toggle_svc; press_key;;
            11) view_log;;
            12) install_xray; restart_svc; press_key;;
            13) create_alias; press_key;;
            0) exit 0;;
            *) echo "无效"; sleep 1;;
        esac
    done
}

press_key() { echo ""; read -n 1 -s -rp "按任意键返回..."; echo ""; }

delete_node() {
    echo ""
    jq -r '.inbounds[] | "  [\(.port)] \(.tag)  (\(.protocol | ascii_upcase))"' "$XRAY_CONFIG" 2>/dev/null
    echo ""
    read -rp "  输入要删除的端口号: " p
    [[ -z "$p" ]] && return
    local tag; tag=$(jq -r --argjson p "$p" '.inbounds[] | select(.port==$p) | .tag' "$XRAY_CONFIG")
    [[ -z "$tag" ]] && { warn "端口 $p 不存在"; return; }
    read -rp "  确定删除端口 $p [$tag]? [y/N]: " c
    [[ ! $c =~ ^[yY]$ ]] && return
    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"
    jq --argjson p "$p" 'del(.inbounds[] | select(.port==$p))' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
    restart_svc
    success "端口 $p 已删除"
    press_key
}

regen_reality_keys() {
    echo ""
    local count; count=$(jq '[.inbounds[] | select(.streamSettings.security=="reality")] | length' "$XRAY_CONFIG" 2>/dev/null || echo 0)
    [[ "$count" -eq 0 ]] && { warn "没有 REALITY 节点"; press_key; return; }
    echo -e "  找到 ${GREEN}${count}${NC} 个 REALITY 节点"
    read -rp "  确定重置所有 REALITY 密钥对? [y/N]: " c
    [[ ! $c =~ ^[yY]$ ]] && return

    local keys; keys=$("$XRAY_BIN" x25519 2>/dev/null)
    local new_pk; new_pk=$(echo "$keys" | extract_xray_key "private")
    local new_pbk; new_pbk=$(echo "$keys" | extract_xray_key "public")
    [[ -z "$new_pk" || -z "$new_pbk" ]] && { error "密钥生成失败"; return; }

    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"
    jq --arg pk "$new_pk" --arg pbk "$new_pbk" \
       '(.inbounds[] | select(.streamSettings.security=="reality") | .streamSettings.realitySettings.privateKey) = $pk' \
       "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" 2>/dev/null
    mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"

    # 更新 node-info
    jq --arg pk "$new_pk" --arg pbk "$new_pbk" \
       'if .type=="reality" or .type=="reality-enc" then .pk=$pk | .pbk=$pbk else . end' \
       "$NODE_INFO" > "${NODE_INFO}.tmp" 2>/dev/null && mv "${NODE_INFO}.tmp" "$NODE_INFO"

    restart_svc
    success "REALITY 密钥已重置，查看分享链接获取新 pbk"
    press_key
}

toggle_svc() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl is-active --quiet xray && { systemctl stop xray; info "已停止"; } || { systemctl start xray; info "已启动"; }
    else
        rc-service xray status 2>/dev/null | grep -qi started && { rc-service xray stop; info "已停止"; } || { rc-service xray start; info "已启动"; }
    fi
}

view_log() {
    echo -e "${YELLOW}实时日志 Ctrl+C 退出...${NC}"
    journalctl -u xray -f --no-pager -n 50 2>/dev/null || tail -F /var/log/xray/*.log 2>/dev/null
}

uninstall_xray() {
    read -rp "确定卸载 Xray? [y/N]: " c
    [[ ! $c =~ ^[yY]$ ]] && return
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop xray 2>/dev/null; systemctl disable xray 2>/dev/null; rm -f /etc/systemd/system/xray.service; systemctl daemon-reload
    else
        rc-service xray stop 2>/dev/null; rc-update del xray 2>/dev/null; rm -f /etc/init.d/xray
    fi
    rm -f "$XRAY_BIN" "$XRAY_CONFIG" "$NODE_INFO"
    rm -rf "$XRAY_DIR" "$XRAY_LOG" /usr/local/share/xray
    rm -f /usr/local/bin/xr
    success "已卸载"
}

create_alias() {
    local script_url="https://raw.githubusercontent.com/charmingyi/xray-vless-install/e3634cb/install.sh"
    echo "#!/bin/bash" > /usr/local/bin/xr
    echo "bash <(curl -sL $script_url)" >> /usr/local/bin/xr
    chmod +x /usr/local/bin/xr
    success "快捷命令已创建: 输入 xr 打开管理面板"
}

restart_svc() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl restart xray; else rc-service xray restart; fi
    sleep 1; info "Xray 已重启"
}

#=============================================================================
main() {
    pre_check

    # 已安装 → 只检查依赖，然后进菜单
    if [[ -f "$XRAY_BIN" && -f "$XRAY_CONFIG" ]]; then
        for c in curl jq; do command -v "$c" &>/dev/null || { install_deps; break; }; done
        main_menu
        exit 0
    fi

    # 首次安装
    install_deps
    install_xray
    install_geodata
    main_menu
}

main "$@"
