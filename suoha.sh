#!/bin/bash

# 用于在无 root 权限的 Debian 系统中通过 Cloudflare 固定隧道设置 Xray + VMess-WebSocket 和可选 SOCKS5 代理
# 优化：动态端口（49152-65535），域名和 UUID 存储，SOCKS5 可选，修复端口冲突，输出配置文件路径
# 新增：定期检查服务状态，日志清理，修复 SOCKS5 无效，处理 ss 别名，修复 status 空输出

# 设置颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log() {
    echo -e "${GREEN}[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1${NC}" | tee -a "$LOG_FILE"
}
error() {
    echo -e "${RED}[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1${NC}" | tee -a "$LOG_FILE" >&2
    exit 1
}

# 配置变量
WORKDIR="$HOME/.suoha"
CLOUDFLARED="$WORKDIR/cloudflared"
LOG_FILE="$WORKDIR/suoha.log"
CONFIG_DIR="$WORKDIR/config"
TUNNEL_CONFIG="$CONFIG_DIR/tunnel.yml"
TOKEN_FILE="$CONFIG_DIR/token"
CONFIG_FILE="$CONFIG_DIR/config.json"
XRAY_BINARY="$WORKDIR/xray"
XRAY_CONFIG="$CONFIG_DIR/inbound.json"
DYNAMIC_PORT_MIN=49152
DYNAMIC_PORT_MAX=65535
WS_PATH_DEFAULT="suoha"
ENABLE_SOCKS5=true
UUID=""
LOG_MAX_SIZE=$((10 * 1024 * 1024)) # 10MB

# 检测系统和架构
OS=$(uname -s)
if [ "$OS" = "Linux" ] && [ -f /etc/debian_version ]; then
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) XRAY_ARCH="64"; CLOUDFLARED_ARCH="amd64" ;;
        aarch64) XRAY_ARCH="arm64-v8a"; CLOUDFLARED_ARCH="arm64" ;;
        *) error "不支持的 Debian 架构：$ARCH" ;;
    esac
    CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CLOUDFLARED_ARCH"
    XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$XRAY_ARCH.zip"
else
    error "仅支持 Debian 系统"
fi

# 检查工具
check_requirements() {
    if ! command -v curl >/dev/null; then
        error "缺少 curl，请安装：sudo apt install curl"
    fi
    if command -v lsof >/dev/null; then
        PORT_CHECKER="lsof"
    elif command -v /bin/ss >/dev/null; then
        PORT_CHECKER="ss"
    elif command -v netstat >/dev/null; then
        PORT_CHECKER="netstat"
    else
        log "警告：未找到 lsof、ss 或 netstat，建议安装 iproute2：sudo apt install iproute2"
        PORT_CHECKER="none"
    fi
    log "使用 $PORT_CHECKER 检查端口"
    if [ -n "$(type -t ss | grep alias)" ]; then
        log "警告：检测到 ss 命令被别名覆盖，尝试取消别名"
        unalias ss 2>/dev/null
    fi
    if [ -d "/home/$USER/serv00-play" ] || [ "$USER" = "nfgtqpug" ]; then
        log "检测到可能运行在 Serv00 环境"
        echo -e "${YELLOW}注意：Serv00 可能限制端口（$DYNAMIC_PORT_MIN-$DYNAMIC_PORT_MAX）或工具（如 ss），请检查防火墙或联系支持${NC}" | tee -a "$LOG_FILE"
    fi
}

# 验证 UUID 格式
validate_uuid() {
    local uuid=$1
    if echo "$uuid" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
        return 0
    else
        error "无效的 UUID 格式，应为 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    fi
}

# 查找可用端口
find_free_port() {
    local exclude_port=$1
    local port=$DYNAMIC_PORT_MIN
    local max_attempts=$((DYNAMIC_PORT_MAX - DYNAMIC_PORT_MIN + 1))
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if [ "$port" != "$exclude_port" ]; then
            case "$PORT_CHECKER" in
                lsof) [ -z "$(lsof -i :$port 2>/dev/null)" ] && echo "$port" && return ;;
                ss) ! /bin/ss -tuln 2>/dev/null | grep -q ":$port " && echo "$port" && return ;;
                netstat) ! netstat -an 2>/dev/null | grep -q ":$port " && echo "$port" && return ;;
                *) log "警告：无端口检查工具，选择端口 $port"; echo "$port"; return ;;
            esac
        fi
        port=$((port + 1))
        [ $port -gt $DYNAMIC_PORT_MAX ] && port=$DYNAMIC_PORT_MIN
        attempt=$((attempt + 1))
    done
    error "无可用端口（$DYNAMIC_PORT_MIN-$DYNAMIC_PORT_MAX）"
}

# 清理端口
cleanup_port() {
    local port=$1
    if [ "$PORT_CHECKER" != "none" ]; then
        local pid=$(lsof -t -i :$port 2>/dev/null || /bin/ss -tuln 2>/dev/null | grep ":$port " | awk '{print $NF}' | head -1)
        if [ -n "$pid" ]; then
            log "端口 $port 被 PID $pid 占用，正在终止..."
            kill -9 "$pid" 2>/dev/null
            sleep 1
            if lsof -i :$port >/dev/null || /bin/ss -tuln 2>/dev/null | grep -q ":$port "; then
                error "无法释放端口 $port"
            fi
        fi
    fi
}

# 检查日志文件大小
check_log_size() {
    if [ -f "$LOG_FILE" ] && [ "$(stat -c %s "$LOG_FILE" 2>/dev/null)" -gt "$LOG_MAX_SIZE" ]; then
        log "日志文件 $LOG_FILE 超过 10MB，正在备份..."
        mv "$LOG_FILE" "$LOG_FILE.bak" 2>/dev/null || error "无法备份日志文件"
        touch "$LOG_FILE"
        chmod 600 "$LOG_FILE" 2>/dev/null || error "无法设置日志文件权限"
        log "日志文件已备份为 $LOG_FILE.bak，新日志文件已创建"
    fi
}

# 验证 SOCKS5 配置
validate_socks5() {
    if [ "$ENABLE_SOCKS5" = true ]; then
        if [ -z "$SOCKS_PORT" ] || [ -z "$SOCKS_USER" ] || [ -z "$SOCKS_PASS" ]; then
            error "SOCKS5 配置不完整：端口、用户名或密码缺失"
        fi
        if [ "$SOCKS_PORT" = "$XRAY_PORT" ]; then
            error "SOCKS5 端口 $SOCKS_PORT 与 VMess 端口冲突"
        fi
        log "SOCKS5 配置验证通过：端口=$SOCKS_PORT, 用户=$SOCKS_USER"
        if [ "$PORT_CHECKER" != "none" ]; then
            if /bin/ss -tuln 2>/dev/null | grep -q ":$SOCKS_PORT "; then
                log "SOCKS5 端口 $SOCKS_PORT 已监听"
            else
                log "警告：SOCKS5 端口 $SOCKS_PORT 未监听，可能需要检查 Xray 配置或防火墙"
            fi
        fi
        if command -v curl >/dev/null; then
            log "测试 SOCKS5 连接..."
            if curl --socks5 "$SOCKS_USER:$SOCKS_PASS@localhost:$SOCKS_PORT" http://ipinfo.io >/dev/null 2>&1; then
                log "SOCKS5 本地连接测试成功"
            else
                log "警告：SOCKS5 本地连接测试失败，请检查防火墙或 Xray 配置"
                echo -e "${YELLOW}请确保 VPS 防火墙允许端口 $SOCKS_PORT（sudo ufw allow $SOCKS_PORT 或检查 Serv00 限制）${NC}" | tee -a "$LOG_FILE"
            fi
        fi
    fi
}

# 加载配置
load_config() {
    check_log_size
    if [ -f "$CONFIG_FILE" ] && [ -f "$TOKEN_FILE" ] && [ -f "$XRAY_CONFIG" ]; then
        DOMAIN=$(grep '"domain":' "$CONFIG_FILE" | sed -n 's|.*"domain": "\([^"]*\)".*|\1|p')
        WS_PATH=$(grep '"ws_path":' "$CONFIG_FILE" | sed -n 's|.*"ws_path": "\([^"]*\)".*|\1|p')
        ENABLE_SOCKS5=$(grep '"enable_socks5":' "$CONFIG_FILE" | sed -n 's|.*"enable_socks5": \([^,]*\).*|\1|p')
        UUID=$(grep '"uuid":' "$CONFIG_FILE" | sed -n 's|.*"uuid": "\([^"]*\)".*|\1|p')
        TUNNEL_TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null)
        XRAY_PORT=$(grep '"port":' "$XRAY_CONFIG" | sed -n '1s|.*"port": \([0-9]*\).*|\1|p')
        if [ "$ENABLE_SOCKS5" = "true" ]; then
            SOCKS_PORT=$(grep '"port":' "$XRAY_CONFIG" | sed -n '2s|.*"port": \([0-9]*\).*|\1|p')
            SOCKS_USER=$(grep '"user":' "$XRAY_CONFIG" | sed -n 's|.*"user": "\([^"]*\)".*|\1|p')
            SOCKS_PASS=$(grep '"pass":' "$XRAY_CONFIG" | sed -n 's|.*"pass": "\([^"]*\)".*|\1|p')
        fi

        if [ -n "$DOMAIN" ] && [ -n "$WS_PATH" ] && [ -n "$UUID" ] && [ -n "$XRAY_PORT" ] && [ -n "$TUNNEL_TOKEN" ] && \
           validate_uuid "$UUID" && { [ "$ENABLE_SOCKS5" != "true" ] || { [ -n "$SOCKS_PORT" ] && [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ] && [ "$SOCKS_PORT" != "$XRAY_PORT" ]; }; }; then
            if [ "$PORT_CHECKER" != "none" ]; then
                if lsof -i :"$XRAY_PORT" >/dev/null || /bin/ss -tuln 2>/dev/null | grep -q ":$XRAY_PORT "; then
                    log "警告：VMess 端口 $XRAY_PORT 被占用，重新分配"
                    cleanup_port "$XRAY_PORT"
                    XRAY_PORT=$(find_free_port "$SOCKS_PORT")
                    create_xray_config
                fi
                if [ "$ENABLE_SOCKS5" = "true" ] && { lsof -i :"$SOCKS_PORT" >/dev/null || /bin/ss -tuln 2>/dev/null | grep -q ":$SOCKS_PORT "; }; then
                    log "警告：SOCKS5 端口 $SOCKS_PORT 被占用，重新分配"
                    cleanup_port "$SOCKS_PORT"
                    SOCKS_PORT=$(find_free_port "$XRAY_PORT")
                    create_xray_config
                fi
            fi
            log "配置加载：DOMAIN=$DOMAIN, WS_PATH=$WS_PATH, UUID=$UUID, VMess_PORT=$XRAY_PORT, SOCKS5=$ENABLE_SOCKS5"
            [ "$ENABLE_SOCKS5" = "true" ] && log "SOCKS5：PORT=$SOCKS_PORT, USER=$SOCKS_USER"
            validate_socks5
            return 0
        else
            log "配置无效：DOMAIN=$DOMAIN, WS_PATH=$WS_PATH, UUID=$UUID, XRAY_PORT=$XRAY_PORT, TUNNEL_TOKEN=${TUNNEL_TOKEN:0:10}..., SOCKS5=$ENABLE_SOCKS5"
            return 1
        fi
    else
        log "配置文件缺失：CONFIG_FILE=$CONFIG_FILE, TOKEN_FILE=$TOKEN_FILE, XRAY_CONFIG=$XRAY_CONFIG"
        return 1
    fi
}

# 保存配置
save_config() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR" 2>>"$LOG_FILE" || error "无法设置 $CONFIG_DIR 权限"
    cat > "$CONFIG_FILE" << EOF
{
  "domain": "$DOMAIN",
  "ws_path": "$WS_PATH",
  "enable_socks5": $ENABLE_SOCKS5,
  "uuid": "$UUID"
}
EOF
    chmod 600 "$CONFIG_FILE" 2>>"$LOG_FILE" || error "无法设置 $CONFIG_FILE 权限"
    log "配置保存至 $CONFIG_FILE"
}

# 获取隧道令牌
get_tunnel_token() {
    if [ -n "$TUNNEL_TOKEN" ]; then
        log "使用现有令牌"
        return
    fi
    echo -e "${YELLOW}请输入 Cloudflare 隧道令牌（格式：eyJ...）：${NC}"
    read -r TUNNEL_TOKEN
    if [ -z "$TUNNEL_TOKEN" ] || ! echo "$TUNNEL_TOKEN" | grep -q '^eyJ'; then
        error "无效的 Cloudflare 隧道令牌"
    fi
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR" 2>>"$LOG_FILE"
    echo "$TUNNEL_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE" 2>>"$LOG_FILE" || error "无法设置 $TOKEN_FILE 权限"
    log "令牌保存至 $TOKEN_FILE"
}

# 获取配置
get_config() {
    if [ -z "$WS_PATH" ]; then
        echo -e "${YELLOW}请输入 WebSocket 路径（默认：$WS_PATH_DEFAULT）：${NC}"
        read -r WS_PATH
        WS_PATH=${WS_PATH:-$WS_PATH_DEFAULT}
        log "WS 路径：$WS_PATH"
    fi
    if [ -z "$DOMAIN" ]; then
        echo -e "${YELLOW}请输入域名（例：example.com）：${NC}"
        read -r DOMAIN
        [ -z "$DOMAIN" ] && error "域名不能为空"
        log "域名：$DOMAIN"
    fi
    if [ -z "$UUID" ]; then
        echo -e "${YELLOW}请输入 UUID（格式：xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx，输入 'auto' 自动生成）：${NC}"
        read -r UUID
        if [ "$UUID" = "auto" ]; then
            UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid) || error "无法生成 UUID"
            log "自动生成 UUID：$UUID"
        else
            validate_uuid "$UUID" || error "请提供有效 UUID"
            log "UUID：$UUID"
        fi
    fi
    if [ -z "$XRAY_PORT" ]; then
        XRAY_PORT=$(find_free_port "$SOCKS_PORT")
        log "VMess 端口：$XRAY_PORT"
    fi
    if [ -z "$ENABLE_SOCKS5" ]; then
        echo -e "${YELLOW}启用 SOCKS5？（y/n，默认 y）：${NC}"
        read -r socks_choice
        case "$socks_choice" in
            n|N) ENABLE_SOCKS5=false ;;
            *) ENABLE_SOCKS5=true ;;
        esac
        log "SOCKS5：$ENABLE_SOCKS5"
    fi
    if [ "$ENABLE_SOCKS5" = true ]; then
        if [ -z "$SOCKS_PORT" ]; then
            SOCKS_PORT=$(find_free_port "$XRAY_PORT")
            log "SOCKS5 端口：$SOCKS_PORT"
        fi
        if [ -z "$SOCKS_USER" ]; then
            echo -e "${YELLOW}请输入 SOCKS5 用户名：${NC}"
            read -r SOCKS_USER
            [ -z "$SOCKS_USER" ] && error "用户名不能为空"
            log "SOCKS5 用户：$SOCKS_USER"
        fi
        if [ -z "$SOCKS_PASS" ]; then
            echo -e "${YELLOW}请输入 SOCKS5 密码：${NC}"
            stty -echo 2>/dev/null; read -r SOCKS_PASS; stty echo 2>/dev/null; echo ""
            [ -z "$SOCKS_PASS" ] && error "密码不能为空"
            log "SOCKS5 密码已设置"
        fi
    fi
    validate_socks5
}

# 下载 cloudflared
download_cloudflared() {
    if [ ! -f "$CLOUDFLARED" ]; then
        log "下载 cloudflared..."
        mkdir -p "$WORKDIR"
        chmod 700 "$WORKDIR" 2>>"$LOG_FILE"
        if ! curl -sL "$CLOUDFLARED_URL" -o "$CLOUDFLARED" 2>>"$LOG_FILE"; then
            error "下载 cloudflared 失败"
        fi
        chmod +x "$CLOUDFLARED" 2>>"$LOG_FILE" || error "无法设置 cloudflared 执行权限"
        log "cloudflared 下载完成"
    fi
}

# 下载 Xray
download_xray() {
    if [ ! -f "$XRAY_BINARY" ]; then
        log "下载 Xray..."
        mkdir -p "$WORKDIR"
        chmod 700 "$WORKDIR" 2>>"$LOG_FILE"
        if ! curl -sL "$XRAY_URL" -o "$WORKDIR/xray.zip" 2>>"$LOG_FILE"; then
            error "下载 Xray 失败"
        fi
        unzip -o "$WORKDIR/xray.zip" xray -d "$WORKDIR" 2>>"$LOG_FILE" && mv "$WORKDIR/xray" "$XRAY_BINARY"
        rm -f "$WORKDIR/xray.zip"
        chmod +x "$XRAY_BINARY" 2>>"$LOG_FILE" || error "无法设置 Xray 执行权限"
        "$XRAY_BINARY" version >/dev/null 2>&1 || { error "Xray 文件无效"; rm -f "$XRAY_BINARY"; }
        log "Xray 下载完成"
    fi
}

# 创建隧道配置
create_tunnel_config() {
    [ -z "$TUNNEL_TOKEN" ] && error "无隧道令牌"
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR" 2>>"$LOG_FILE"
    cat > "$TUNNEL_CONFIG" << EOF
tunnel: suoha-tunnel
credentials-file: $CONFIG_DIR/credentials.json
logfile: $LOG_FILE
ingress:
  - hostname: $DOMAIN
    service: http://localhost:$XRAY_PORT
  - service: http_status:404
EOF
    chmod 600 "$TUNNEL_CONFIG" 2>>"$LOG_FILE" || error "无法设置 $TUNNEL_CONFIG 权限"
    log "隧道配置创建：$TUNNEL_CONFIG"
    log "注意：SOCKS5 不通过隧道，直接使用本地端口 $SOCKS_PORT"
}

# 创建 Xray 配置
create_xray_config() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR" 2>>"$LOG_FILE"
    log "生成 Xray 配置，VMess 端口：$XRAY_PORT, UUID：$UUID"
    cat > "$XRAY_CONFIG" << EOF
{
  "log": {
    "loglevel": "debug",
    "access": "$LOG_FILE",
    "error": "$LOG_FILE"
  },
  "inbounds": [
    {
      "port": $XRAY_PORT,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/$WS_PATH"
        }
      }
    }
EOF
    if [ "$ENABLE_SOCKS5" = true ]; then
        log "添加 SOCKS5 配置，端口：$SOCKS_PORT"
        cat >> "$XRAY_CONFIG" << EOF
    ,
    {
      "listen": "0.0.0.0",
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          {
            "user": "$SOCKS_USER",
            "pass": "$SOCKS_PASS"
          }
        ],
        "udp": true
      }
    }
EOF
    fi
    cat >> "$XRAY_CONFIG" << EOF
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF
    chmod 600 "$XRAY_CONFIG" 2>>"$LOG_FILE" || error "无法设置 $XRAY_CONFIG 权限"
    log "Xray 配置创建：$XRAY_CONFIG"
    validate_socks5
}

# 输出代理信息
output_proxy_node() {
    VMESS_JSON=$(cat << EOF
{
  "v": "2",
  "ps": "suoha-node-vmess",
  "add": "$DOMAIN",
  "port": "443",
  "id": "$UUID",
  "aid": 0,
  "scy": "auto",
  "net": "ws",
  "path": "/$WS_PATH",
  "type": "none",
  "host": "$DOMAIN",
  "tls": "tls",
  "sni": "$DOMAIN"
}
EOF
)
    VMESS_BASE64=$(echo "$VMESS_JSON" | base64 | tr -d '\n')
    echo -e "${YELLOW}=== 配置文件路径 ==="${NC}
    echo -e "主配置文件：$CONFIG_FILE"
    echo -e "Xray 配置文件：$XRAY_CONFIG"
    echo -e "Cloudflare 隧道配置：$TUNNEL_CONFIG"
    echo -e "${YELLOW}=== 代理节点配置 ==="${NC}
    echo -e "1. VMess"
    echo -e "地址: $DOMAIN"
    echo -e "端口: 443"
    echo -e "UUID: $UUID"
    echo -e "路径: /$WS_PATH"
    echo -e "TLS: 启用"
    echo -e "SNI: $DOMAIN"
    echo -e "链接: vmess://$VMESS_BASE64"
    if [ "$ENABLE_SOCKS5" = true ]; then
        echo -e "\n2. SOCKS5（直接使用本地端口，不通过 Cloudflare 隧道）"
        echo -e "地址: localhost 或 VPS IP"
        echo -e "端口: $SOCKS_PORT"
        echo -e "用户名: $SOCKS_USER"
        echo -e "密码: $SOCKS_PASS"
        echo -e "${YELLOW}测试 SOCKS5：curl --socks5 $SOCKS_USER:$SOCKS_PASS@localhost:$SOCKS_PORT http://ipinfo.io${NC}"
        echo -e "${YELLOW}注意：请确保 VPS 防火墙允许端口 $SOCKS_PORT（sudo ufw allow $SOCKS_PORT 或检查 Serv00 限制）${NC}"
    fi
    echo -e "\n日志文件：$LOG_FILE"
    echo -e "Cloudflare 路由："
    echo -e "  - https://$DOMAIN:$XRAY_PORT (VMess)"
}

# 清理 Xray 进程
cleanup_xray() {
    if ps aux | grep -v grep | grep "$XRAY_BINARY" >/dev/null; then
        log "清理 Xray 进程..."
        pkill -f "$XRAY_BINARY" 2>/dev/null
        sleep 1
        ps aux | grep -v grep | grep "$XRAY_BINARY" >/dev/null && error "无法清理 Xray 进程"
        log "Xray 进程已清理"
    fi
    cleanup_port 8080
}

# 运行隧道
run_tunnel() {
    ps aux | grep -v grep | grep "$CLOUDFLARED.*--token" >/dev/null && error "隧道已在运行"
    log "启动隧道..."
    nohup "$CLOUDFLARED" tunnel --config "$TUNNEL_CONFIG" run --token "$TUNNEL_TOKEN" >> "$LOG_FILE" 2>&1 &
    TUNNEL_PID=$!
    sleep 5
    ps -p "$TUNNEL_PID" >/dev/null || error "隧道启动失败\n最近的日志：\n$(tail -n 20 "$LOG_FILE")"
    log "隧道运行，PID：$TUNNEL_PID"
}

# 运行 Xray
run_xray() {
    cleanup_xray
    if [ "$PORT_CHECKER" != "none" ]; then
        if lsof -i :"$XRAY_PORT" >/dev/null || /bin/ss -tuln 2>/dev/null | grep -q ":$XRAY_PORT "; then
            log "警告：VMess 端口 $XRAY_PORT 被占用，重新分配"
            cleanup_port "$XRAY_PORT"
            XRAY_PORT=$(find_free_port "$SOCKS_PORT")
            create_xray_config
        fi
        if [ "$ENABLE_SOCKS5" = "true" ]; then
            if [ -z "$SOCKS_PORT" ]; then
                error "SOCKS5 端口未定义"
            fi
            if lsof -i :"$SOCKS_PORT" >/dev/null || /bin/ss -tuln 2>/dev/null | grep -q ":$SOCKS_PORT "; then
                log "警告：SOCKS5 端口 $SOCKS_PORT 被占用，重新分配"
                cleanup_port "$SOCKS_PORT"
                SOCKS_PORT=$(find_free_port "$XRAY_PORT")
                create_xray_config
            fi
        fi
    fi
    log "启动 Xray..."
    nohup "$XRAY_BINARY" run -c "$XRAY_CONFIG" >> "$LOG_FILE" 2>&1 &
    XRAY_PID=$!
    sleep 2
    if ps -p "$XRAY_PID" >/dev/null; then
        log "Xray 运行，PID：$XRAY_PID，VMess 端口：$XRAY_PORT"
        [ "$ENABLE_SOCKS5" = true ] && log "SOCKS5 端口：$SOCKS_PORT"
        if [ "$ENABLE_SOCKS5" = true ] && [ "$PORT_CHECKER" != "none" ]; then
            if /bin/ss -tuln 2>/dev/null | grep -q ":$SOCKS_PORT "; then
                log "SOCKS5 端口 $SOCKS_PORT 正在监听"
            else
                error "SOCKS5 端口 $SOCKS_PORT 未监听，请检查 Xray 配置\n最近的日志：\n$(tail -n 20 "$LOG_FILE")"
            fi
        fi
    else
        error "Xray 启动失败\n最近的日志：\n$(tail -n 20 "$LOG_FILE")"
    fi
}

# 停止服务
stop_services() {
    log "停止服务..."
    pkill -f "$CLOUDFLARED" 2>/dev/null && log "隧道已停止"
    cleanup_xray
}

# 检查状态
check_status() {
    local tunnel_running=false
    local xray_running=false
    local status_output=""

    # 加载配置以获取端口信息
    if ! load_config; then
        status_output="${RED}无法加载配置，请运行 './suoha.sh config' 初始化${NC}\n"
    fi

    # 检查隧道
    if ps aux | grep -v grep | grep "$CLOUDFLARED.*--token" >/dev/null; then
        tunnel_running=true
        status_output+="${GREEN}隧道运行（PID: $(ps aux | grep -v grep | grep "$CLOUDFLARED.*--token" | awk '{print $2}'))${NC}\n"
    else
        status_output+="${RED}隧道未运行${NC}\n"
    fi

    # 检查 Xray
    if ps aux | grep -v grep | grep "$XRAY_BINARY" >/dev/null; then
        xray_running=true
        status_output+="${GREEN}Xray 运行（PID: $(ps aux | grep -v grep | grep "$XRAY_BINARY" | awk '{print $2}')，VMess 端口：$XRAY_PORT"
        [ "$ENABLE_SOCKS5" = true ] && status_output+="，SOCKS5 端口：$SOCKS_PORT"
        status_output+="${NC}\n"
    else
        status_output+="${RED}Xray 未运行${NC}\n"
    fi

    # 检查端口
    if [ "$PORT_CHECKER" != "none" ] && [ "$ENABLE_SOCKS5" = true ] && [ -n "$SOCKS_PORT" ]; then
        if /bin/ss -tuln 2>/dev/null | grep -q ":$SOCKS_PORT "; then
            status_output+="${GREEN}SOCKS5 端口 $SOCKS_PORT 正在监听${NC}\n"
        else
            status_output+="${YELLOW}SOCKS5 端口 $SOCKS_PORT 未监听，可能未启动或被防火墙阻止${NC}\n"
        fi
    fi

    # 输出状态
    echo -e "$status_output"
    if [ "$tunnel_running" = false ] || [ "$xray_running" = false ]; then
        return 1
    fi
    return 0
}

# 设置定期监控
setup_monitor() {
    log "设置服务状态监控（每 5 分钟检查）..."
    CRON_JOB="*/5 * * * * $HOME/suoha.sh monitor"
    (crontab -l 2>/dev/null | grep -v "$HOME/suoha.sh monitor"; echo "$CRON_JOB") | crontab - || error "无法设置监控 crontab"
    log "服务状态监控已配置，每 5 分钟检查"
}

# 监控服务状态并重启
monitor_services() {
    check_log_size
    if ! check_status; then
        log "服务未全部运行，尝试重启..."
        stop_services
        sleep 2
        check_requirements
        if ! load_config; then
            log "配置无效，无法自动重启，请运行 './suoha.sh config' 更新配置"
            exit 1
        fi
        download_cloudflared
        download_xray
        create_tunnel_config
        run_tunnel
        run_xray
        output_proxy_node
    else
        log "服务状态正常，无需重启"
    fi
}

# 自动启动
setup_autostart() {
    log "设置自动启动..."
    CRON_JOB="@reboot sleep 30 && $HOME/suoha.sh start"
    (crontab -l 2>/dev/null | grep -v "$HOME/suoha.sh start"; echo "$CRON_JOB") | crontab - || error "无法设置 crontab"
    log "自动启动已配置，系统重启后延迟 30 秒启动"
}

# 解析参数
while [ $# -gt 0 ]; do
    case "$1" in
        --no-socks5) ENABLE_SOCKS5=false; shift ;;
        --uuid)
            UUID=$2
            validate_uuid "$UUID" || error "无效的 UUID 参数"
            shift 2
            ;;
        *) break ;;
    esac
done

# 主逻辑
case "$1" in
    start)
        check_requirements
        check_log_size
        if ! load_config; then
            get_tunnel_token
            get_config
            save_config
            create_xray_config
        fi
        download_cloudflared
        download_xray
        create_tunnel_config
        run_tunnel
        run_xray
        output_proxy_node
        ;;
    stop)
        stop_services
        ;;
    restart)
        stop_services
        sleep 2
        check_requirements
        check_log_size
        if ! load_config; then
            get_tunnel_token
            get_config
            save_config
            create_xray_config
        fi
        download_cloudflared
        download_xray
        create_tunnel_config
        run_tunnel
        run_xray
        output_proxy_node
        ;;
    status)
        check_requirements
        check_status
        ;;
    autostart)
        check_requirements
        check_log_size
        if ! load_config; then
            get_tunnel_token
            get_config
            save_config
            create_xray_config
        fi
        download_cloudflared
        download_xray
        create_tunnel_config
        setup_autostart
        output_proxy_node
        ;;
    config)
        check_requirements
        check_log_size
        get_tunnel_token
        get_config
        save_config
        create_xray_config
        log "配置已更新，运行 './suoha.sh start' 启动"
        output_proxy_node
        ;;
    monitor)
        monitor_services
        ;;
    monitor-setup)
        check_requirements
        check_log_size
        if ! load_config; then
            get_tunnel_token
            get_config
            save_config
            create_xray_config
        fi
        download_cloudflared
        download_xray
        create_tunnel_config
        setup_monitor
        output_proxy_node
        ;;
    *)
        echo -e "${YELLOW}用法：$0 {start|stop|restart|status|autostart|config|monitor|monitor-setup} [--no-socks5] [--uuid <UUID>]${NC}"
        echo -e "  start: 启动服务"
        echo -e "  stop: 停止服务"
        echo -e "  restart: 重启服务"
        echo -e "  status: 检查服务状态"
        echo -e "  autostart: 配置系统重启后自动启动"
        echo -e "  config: 更新配置"
        echo -e "  monitor: 检查服务状态并重启"
        echo -e "  monitor-setup: 配置定期监控"
        exit 1
        ;;
esac
