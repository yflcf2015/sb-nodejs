#!/bin/bash

# 用于在无 root 权限的 Debian 系统中通过 Cloudflare 固定隧道设置 Xray + VMess-WebSocket 和可选 SOCKS5 代理
# 优化：动态端口（49152-65535），域名和 UUID 存储，SOCKS5 可选，修复端口冲突

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

# 检测系统和架构
OS=$(uname -s)
if [ "$OS" = "Linux" ] && [ -f /etc/debian_version ]; then
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) XRAY_ARCH="64"; CLOUDFLARED_ARCH="amd64" ;;
        aarch64) XRAY_ARCH="arm64-v8a"; CLOUDFLARED_ARCH="arm64" ;;
        *) echo "错误：不支持的 Debian 架构：$ARCH" | tee -a "$LOG_FILE"; exit 1 ;;
    esac
    CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CLOUDFLARED_ARCH"
    XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v1.8.24/Xray-linux-$XRAY_ARCH.zip"
else
    echo "错误：仅支持 Debian 系统。" | tee -a "$LOG_FILE"; exit 1
fi

# 检查工具
check_requirements() {
    if ! command -v curl >/dev/null; then
        echo "错误：缺少 curl。请安装：sudo apt install curl" | tee -a "$LOG_FILE"
        exit 1
    fi
    if command -v lsof >/dev/null; then
        PORT_CHECKER="lsof"
    elif command -v ss >/dev/null; then
        PORT_CHECKER="ss"
    elif command -v netstat >/dev/null; then
        PORT_CHECKER="netstat"
    else
        echo "警告：未找到 lsof、ss 或 netstat，建议安装 lsof：sudo apt install lsof" | tee -a "$LOG_FILE"
        PORT_CHECKER="none"
    fi
    echo "使用 $PORT_CHECKER 检查端口。" >> "$LOG_FILE"
}

# 验证 UUID 格式
validate_uuid() {
    local uuid=$1
    if echo "$uuid" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
        return 0
    else
        echo "错误：无效的 UUID 格式。应为 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" | tee -a "$LOG_FILE"
        return 1
    fi
}

# 查找可用端口
find_free_port() {
    port=$DYNAMIC_PORT_MIN
    max_attempts=$((DYNAMIC_PORT_MAX - DYNAMIC_PORT_MIN + 1))
    attempt=0
    while [ $attempt -lt $max_attempts ]; do
        case "$PORT_CHECKER" in
            lsof) [ -z "$(lsof -i :$port 2>/dev/null)" ] && echo "$port" && return ;;
            ss) ! ss -a | grep -q ":$port " && echo "$port" && return ;;
            netstat) ! netstat -an | grep -q ":$port " && echo "$port" && return ;;
            *) echo "警告：无端口检查工具，选择端口 $port" | tee -a "$LOG_FILE"; echo "$port"; return ;;
        esac
        port=$((port + 1))
        [ $port -gt $DYNAMIC_PORT_MAX ] && port=$DYNAMIC_PORT_MIN
        attempt=$((attempt + 1))
    done
    echo "错误：无可用端口（$DYNAMIC_PORT_MIN-$DYNAMIC_PORT_MAX）。" | tee -a "$LOG_FILE"
    exit 1
}

# 清理端口
cleanup_port() {
    port=$1
    if [ "$PORT_CHECKER" != "none" ]; then
        pid=$(lsof -t -i :$port 2>/dev/null || ss -a | grep ":$port " | awk '{print $NF}' | head -1)
        if [ -n "$pid" ]; then
            echo "端口 $port 被 PID $pid 占用，正在终止..." | tee -a "$LOG_FILE"
            kill -9 "$pid" 2>/dev/null
            sleep 1
            if lsof -i :$port >/dev/null || ss -a | grep -q ":$port "; then
                echo "错误：无法释放端口 $port。" | tee -a "$LOG_FILE"
                exit 1
            fi
        fi
    fi
}

# 加载配置
load_config() {
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
           validate_uuid "$UUID" && { [ "$ENABLE_SOCKS5" != "true" ] || { [ -n "$SOCKS_PORT" ] && [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; }; }; then
            if [ "$PORT_CHECKER" != "none" ]; then
                if lsof -i :"$XRAY_PORT" >/dev/null || ss -a | grep -q ":$XRAY_PORT "; then
                    echo "警告：VMess 端口 $XRAY_PORT 被占用，重新分配。" | tee -a "$LOG_FILE"
                    cleanup_port "$XRAY_PORT"
                    XRAY_PORT=$(find_free_port)
                fi
                if [ "$ENABLE_SOCKS5" = "true" ] && { lsof -i :"$SOCKS_PORT" >/dev/null || ss -a | grep -q ":$SOCKS_PORT "; }; then
                    echo "警告：SOCKS5 端口 $SOCKS_PORT 被占用，重新分配。" | tee -a "$LOG_FILE"
                    cleanup_port "$SOCKS_PORT"
                    SOCKS_PORT=$(find_free_port)
                fi
            fi
            echo "配置加载：DOMAIN=$DOMAIN, WS_PATH=$WS_PATH, UUID=$UUID, VMess_PORT=$XRAY_PORT, SOCKS5=$ENABLE_SOCKS5" | tee -a "$LOG_FILE"
            [ "$ENABLE_SOCKS5" = "true" ] && echo "SOCKS5：PORT=$SOCKS_PORT, USER=$SOCKS_USER" | tee -a "$LOG_FILE"
            return 0
        fi
    fi
    echo "警告：配置不完整或 UUID 无效，需重新配置。" | tee -a "$LOG_FILE"
    return 1
}

# 保存配置
save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << EOF
{
  "domain": "$DOMAIN",
  "ws_path": "$WS_PATH",
  "enable_socks5": $ENABLE_SOCKS5,
  "uuid": "$UUID"
}
EOF
    chmod 600 "$CONFIG_FILE" 2>>"$LOG_FILE"
    echo "配置保存至 $CONFIG_FILE" | tee -a "$LOG_FILE"
}

# 获取隧道令牌
get_tunnel_token() {
    if [ -n "$TUNNEL_TOKEN" ]; then
        echo "使用现有令牌。" | tee -a "$LOG_FILE"
        return
    fi
    echo "请输入 Cloudflare 隧道令牌（格式：eyJ...）："
    read -r TUNNEL_TOKEN
    if [ -z "$TUNNEL_TOKEN" ] || ! echo "$TUNNEL_TOKEN" | grep -q '^eyJ'; then
        echo "错误：无效令牌。" | tee -a "$LOG_FILE"
        exit 1
    fi
    mkdir -p "$CONFIG_DIR"
    echo "$TUNNEL_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE" 2>>"$LOG_FILE"
    echo "令牌保存至 $TOKEN_FILE" | tee -a "$LOG_FILE"
}

# 获取配置
get_config() {
    if [ -z "$WS_PATH" ]; then
        echo "请输入 WebSocket 路径（默认：$WS_PATH_DEFAULT）："
        read -r WS_PATH
        WS_PATH=${WS_PATH:-$WS_PATH_DEFAULT}
        echo "WS 路径：$WS_PATH" | tee -a "$LOG_FILE"
    fi
    if [ -z "$DOMAIN" ]; then
        echo "请输入域名（例：example.com）："
        read -r DOMAIN
        [ -z "$DOMAIN" ] && { echo "错误：域名不能为空。" | tee -a "$LOG_FILE"; exit 1; }
        echo "域名：$DOMAIN" | tee -a "$LOG_FILE"
    fi
    if [ -z "$UUID" ]; then
        echo "请输入 UUID（格式：xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx）："
        read -r UUID
        if ! validate_uuid "$UUID"; then
            echo "错误：请提供有效 UUID。" | tee -a "$LOG_FILE"
            exit 1
        fi
        echo "UUID：$UUID" | tee -a "$LOG_FILE"
    fi
    if [ -z "$XRAY_PORT" ]; then
        XRAY_PORT=$(find_free_port)
        echo "VMess 端口：$XRAY_PORT" | tee -a "$LOG_FILE"
    fi
    if [ -z "$ENABLE_SOCKS5" ]; then
        echo "启用 SOCKS5？（y/n，默认 y）："
        read -r socks_choice
        case "$socks_choice" in
            n|N) ENABLE_SOCKS5=false ;;
            *) ENABLE_SOCKS5=true ;;
        esac
        echo "SOCKS5：$ENABLE_SOCKS5" | tee -a "$LOG_FILE"
    fi
    if [ "$ENABLE_SOCKS5" = true ]; then
        if [ -z "$SOCKS_PORT" ]; then
            SOCKS_PORT=$(find_free_port)
            echo "SOCKS5 端口：$SOCKS_PORT" | tee -a "$LOG_FILE"
        fi
        if [ -z "$SOCKS_USER" ]; then
            echo "请输入 SOCKS5 用户名："
            read -r SOCKS_USER
            [ -z "$SOCKS_USER" ] && { echo "错误：用户名不能为空。" | tee -a "$LOG_FILE"; exit 1; }
            echo "SOCKS5 用户：$SOCKS_USER" | tee -a "$LOG_FILE"
        fi
        if [ -z "$SOCKS_PASS" ]; then
            echo "请输入 SOCKS5 密码："
            stty -echo 2>/dev/null; read -r SOCKS_PASS; stty echo 2>/dev/null; echo ""
            [ -z "$SOCKS_PASS" ] && { echo "错误：密码不能为空。" | tee -a "$LOG_FILE"; exit 1; }
            echo "SOCKS5 密码已设置" | tee -a "$LOG_FILE"
        fi
    fi
}

# 下载 cloudflared
download_cloudflared() {
    if [ ! -f "$CLOUDFLARED" ]; then
        echo "下载 cloudflared..." | tee -a "$LOG_FILE"
        mkdir -p "$WORKDIR"
        if ! curl -sL "$CLOUDFLARED_URL" -o "$CLOUDFLARED" 2>>"$LOG_FILE"; then
            echo "错误：下载 cloudflared 失败。" | tee -a "$LOG_FILE"
            exit 1
        fi
        chmod +x "$CLOUDFLARED" 2>>"$LOG_FILE"
        echo "cloudflared 下载完成。" >> "$LOG_FILE"
    fi
}

# 下载 Xray
download_xray() {
    if [ ! -f "$XRAY_BINARY" ]; then
        echo "下载 Xray..." | tee -a "$LOG_FILE"
        mkdir -p "$WORKDIR"
        if ! curl -sL "$XRAY_URL" -o "$WORKDIR/xray.zip" 2>>"$LOG_FILE"; then
            echo "错误：下载 Xray 失败。" | tee -a "$LOG_FILE"
            exit 1
        fi
        unzip -o "$WORKDIR/xray.zip" xray -d "$WORKDIR" 2>>"$LOG_FILE" && mv "$WORKDIR/xray" "$XRAY_BINARY"
        rm -f "$WORKDIR/xray.zip"
        chmod +x "$XRAY_BINARY" 2>>"$LOG_FILE"
        "$XRAY_BINARY" version >/dev/null 2>&1 || { echo "错误：Xray 文件无效。" | tee -a "$LOG_FILE"; rm -f "$XRAY_BINARY"; exit 1; }
        echo "Xray 下载完成。" >> "$LOG_FILE"
    fi
}

# 创建隧道配置
create_tunnel_config() {
    [ -z "$TUNNEL_TOKEN" ] && { echo "错误：无隧道令牌。" | tee -a "$LOG_FILE"; exit 1; }
    mkdir -p "$CONFIG_DIR"
    cat > "$TUNNEL_CONFIG" << EOF
tunnel: suoha-tunnel
credentials-file: $CONFIG_DIR/credentials.json
logfile: $LOG_FILE
url: https://$DOMAIN:$XRAY_PORT
EOF
    chmod 600 "$TUNNEL_CONFIG" 2>>"$LOG_FILE"
    echo "隧道配置创建：$TUNNEL_CONFIG" | tee -a "$LOG_FILE"
}

# 创建 Xray 配置
create_xray_config() {
    mkdir -p "$CONFIG_DIR"
    echo "生成 Xray 配置，VMess 端口：$XRAY_PORT, UUID：$UUID" | tee -a "$LOG_FILE"
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
        echo "添加 SOCKS5 配置，端口：$SOCKS_PORT" | tee -a "$LOG_FILE"
        cat >> "$XRAY_CONFIG" << EOF
    ,
    {
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
    chmod 600 "$XRAY_CONFIG" 2>>"$LOG_FILE"
    echo "Xray 配置创建：$XRAY_CONFIG" | tee -a "$LOG_FILE"
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
    echo -e "\n=== 代理节点配置 ==="
    echo "1. VMess"
    echo "地址: $DOMAIN"
    echo "端口: 443"
    echo "UUID: $UUID"
    echo "路径: /$WS_PATH"
    echo "TLS: 启用"
    echo "SNI: $DOMAIN"
    echo "链接: vmess://$VMESS_BASE64"
    if [ "$ENABLE_SOCKS5" = true ]; then
        echo -e "\n2. SOCKS5"
        echo "地址: $DOMAIN"
        echo "端口: 443"
        echo "本地端口: $SOCKS_PORT"
        echo "用户名: $SOCKS_USER"
        echo "密码: $SOCKS_PASS"
    fi
    echo -e "\n日志：$LOG_FILE"
    echo "Cloudflare 路由："
    echo "  - https://$DOMAIN:$XRAY_PORT (VMess)"
    [ "$ENABLE_SOCKS5" = true ] && echo "  - https://$DOMAIN:$SOCKS_PORT (SOCKS5)"
}

# 清理 Xray 进程
cleanup_xray() {
    if ps aux | grep -v grep | grep "$XRAY_BINARY" >/dev/null; then
        echo "清理 Xray 进程..." | tee -a "$LOG_FILE"
        pkill -f "$XRAY_BINARY" 2>/dev/null
        sleep 1
        ps aux | grep -v grep | grep "$XRAY_BINARY" >/dev/null && { echo "错误：无法清理 Xray 进程。" | tee -a "$LOG_FILE"; exit 1; }
        echo "Xray 进程已清理。" | tee -a "$LOG_FILE"
    fi
    cleanup_port 8080
}

# 运行隧道
run_tunnel() {
    ps aux | grep -v grep | grep "$CLOUDFLARED.*--token" >/dev/null && { echo "错误：隧道已在运行。" | tee -a "$LOG_FILE"; exit 1; }
    echo "启动隧道..." | tee -a "$LOG_FILE"
    nohup "$CLOUDFLARED" tunnel --config "$TUNNEL_CONFIG" run --token "$TUNNEL_TOKEN" >> "$LOG_FILE" 2>&1 &
    TUNNEL_PID=$!
    sleep 5
    ps -p "$TUNNEL_PID" >/dev/null || { echo "错误：隧道启动失败。" | tee -a "$LOG_FILE"; exit 1; }
    echo "隧道运行，PID：$TUNNEL_PID" | tee -a "$LOG_FILE"
}

# 运行 Xray
run_xray() {
    cleanup_xray
    if [ "$PORT_CHECKER" != "none" ]; then
        if lsof -i :"$XRAY_PORT" >/dev/null || ss -a | grep -q ":$XRAY_PORT "; then
            echo "警告：VMess 端口 $XRAY_PORT 被占用，重新分配。" | tee -a "$LOG_FILE"
            cleanup_port "$XRAY_PORT"
            XRAY_PORT=$(find_free_port)
            create_xray_config
        fi
        if [ "$ENABLE_SOCKS5" = true ] && { lsof -i :"$SOCKS_PORT" >/dev/null || ss -a | grep -q ":$SOCKS_PORT "; }; then
            echo "警告：SOCKS5 端口 $SOCKS_PORT 被占用，重新分配。" | tee -a "$LOG_FILE"
            cleanup_port "$SOCKS_PORT"
            SOCKS_PORT=$(find_free_port)
            create_xray_config
        fi
    fi
    echo "启动 Xray..." | tee -a "$LOG_FILE"
    nohup "$XRAY_BINARY" run -c "$XRAY_CONFIG" >> "$LOG_FILE" 2>&1 &
    XRAY_PID=$!
    sleep 2
    if ps -p "$XRAY_PID" >/dev/null; then
        echo "Xray 运行，PID：$XRAY_PID，VMess 端口：$XRAY_PORT" | tee -a "$LOG_FILE"
        [ "$ENABLE_SOCKS5" = true ] && echo "SOCKS5 端口：$SOCKS_PORT" | tee -a "$LOG_FILE"
    else
        echo "错误：Xray 启动失败。" | tee -a "$LOG_FILE"
        tail -n 20 "$LOG_FILE"
        exit 1
    fi
}

# 停止服务
stop_services() {
    echo "停止服务..." | tee -a "$LOG_FILE"
    pkill -f "$CLOUDFLARED" 2>/dev/null && echo "隧道已停止。" | tee -a "$LOG_FILE"
    cleanup_xray
}

# 检查状态
check_status() {
    ps aux | grep -v grep | grep "$CLOUDFLARED.*--token" >/dev/null && echo "隧道运行（PID: $(ps aux | grep -v grep | grep "$CLOUDFLARED.*--token" | awk '{print $2}'))" || echo "隧道未运行。"
    ps aux | grep -v grep | grep "$XRAY_BINARY" >/dev/null && echo "Xray 运行（PID: $(ps aux | grep -v grep | grep "$XRAY_BINARY" | awk '{print $2}')，VMess 端口：$XRAY_PORT$(if [ "$ENABLE_SOCKS5" = true ]; then echo "，SOCKS5 端口：$SOCKS_PORT"; fi)" || echo "Xray 未运行。"
}

# 自动启动
setup_autostart() {
    echo "设置自动启动..." | tee -a "$LOG_FILE"
    CRON_JOB="@reboot $HOME/suoha.sh start"
    (crontab -l 2>/dev/null | grep -v "$HOME/suoha.sh start"; echo "$CRON_JOB") | crontab - || { echo "错误：无法设置 crontab。" | tee -a "$LOG_FILE"; exit 1; }
    echo "自动启动已配置。" | tee -a "$LOG_FILE"
}

# 解析参数
while [ $# -gt 0 ]; do
    case "$1" in
        --no-socks5) ENABLE_SOCKS5=false; shift ;;
        --uuid)
            UUID=$2
            if ! validate_uuid "$UUID"; then
                echo "错误：无效的 UUID 参数。"
                exit 1
            fi
            shift 2
            ;;
        *) break ;;
    esac
done

# 主逻辑
case "$1" in
    start)
        check_requirements
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
        check_status
        ;;
    autostart)
        check_requirements
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
        get_tunnel_token
        get_config
        save_config
        create_xray_config
        echo "配置已更新，运行 './suoha.sh start' 启动。" | tee -a "$LOG_FILE"
        output_proxy_node
        ;;
    *)
        echo "用法：$0 {start|stop|restart|status|autostart|config} [--no-socks5] [--uuid <UUID>]"
        exit 1
        ;;
esac
