#!/bin/bash
set -e

# ============================================================
# HTTP 代理服务器一键部署脚本（Squid + Basic Auth）
# 适用系统：Debian 11 / 12 / 13
# 用法：bash setup-proxy.sh [-p 端口] [-u 用户名] [-k 密码] [-d DNS]
#
# 安全须知：本脚本部署的是 HTTP 明文代理 + Basic Auth，凭证在
#   客户端与代理之间未加密传输。建议仅在内网、VPN 或 SSH 隧道
#   内使用，或配合防火墙限制源 IP。公网暴露请另行加密（stunnel/
#   WireGuard 等）。
# ============================================================

# ---------- 默认参数 ----------
PROXY_PORT=38181
PROXY_USER="kevin"
PROXY_PASS=""
DNS_SERVERS=""
USER_SPECIFIED=false
PASS_SPECIFIED=false

# ---------- 解析命令行参数 ----------
while getopts "p:u:k:d:h" opt; do
    case $opt in
        p)
            if ! [[ "$OPTARG" =~ ^[0-9]+$ ]] || [ "$OPTARG" -lt 1 ] || [ "$OPTARG" -gt 65535 ]; then
                echo "错误: 端口号必须为 1-65535 的整数"; exit 1
            fi
            PROXY_PORT="$OPTARG"
            ;;
        u) PROXY_USER="$OPTARG"; USER_SPECIFIED=true ;;
        k) PROXY_PASS="$OPTARG"; PASS_SPECIFIED=true ;;
        d) DNS_SERVERS="$OPTARG" ;;
        h)
            echo "用法: bash setup-proxy.sh [-p 端口] [-u 用户名] [-k 密码] [-d DNS]"
            echo "  -p  监听端口（默认 38181）"
            echo "  -u  初始用户名（默认 kevin）"
            echo "  -k  初始密码（默认随机生成 16 位）"
            echo "  -d  自定义 DNS（如 \"8.8.8.8 1.1.1.1\"，默认使用系统解析器）"
            exit 0
            ;;
        *) echo "未知参数，使用 -h 查看帮助"; exit 1 ;;
    esac
done

# ---------- 辅助函数 ----------
info()  { echo -e "\033[32m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[31m[ERROR]\033[0m $*"; exit 1; }

user_in_passwd() {
    awk -F: -v u="$1" '$1 == u { found=1; exit } END { exit !found }' "$2"
}

validate_username() {
    if ! [[ "$1" =~ ^[a-z0-9._-]+$ ]]; then
        error "用户名只允许小写字母、数字、点、下划线和连字符: $1"
    fi
}

validate_password() {
    local re='^[A-Za-z0-9._~!*()-]+$'
    if ! [[ "$1" =~ $re ]]; then
        error "密码含不安全字符（会导致代理 URL 解析错误），仅允许: A-Za-z0-9 . _ ~ ! * ( ) -"
    fi
}

validate_dns() {
    local ip_re='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    local ipv6_re='^[0-9a-fA-F:]+$'
    for addr in $1; do
        if ! [[ "$addr" =~ $ip_re ]] && ! [[ "$addr" =~ $ipv6_re ]]; then
            error "无效的 DNS 地址: $addr（仅接受空格分隔的 IPv4/IPv6 地址）"
        fi
    done
}

# 未指定密码时随机生成
if [ "$PASS_SPECIFIED" = "false" ]; then
    PROXY_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
elif [ -z "$PROXY_PASS" ]; then
    error "密码不能为空（-k 参数值不能为空字符串）"
fi

# 校验用户名和密码字符
validate_username "$PROXY_USER"
validate_password "$PROXY_PASS"
if [ -n "$DNS_SERVERS" ]; then
    validate_dns "$DNS_SERVERS"
fi

# ---------- 步骤 1：环境检查 ----------
info "检查运行环境..."

[ "$(id -u)" -eq 0 ] || error "请以 root 权限运行此脚本"

if [ ! -f /etc/debian_version ]; then
    error "此脚本仅支持 Debian 系统"
fi
DEBIAN_VER=$(cut -d. -f1 < /etc/debian_version)
info "检测到 Debian $DEBIAN_VER"

if ss -tlnp | grep -q ":${PROXY_PORT} " 2>/dev/null; then
    EXISTING=$(ss -tlnp | grep ":${PROXY_PORT} " | awk '{print $NF}')
    warn "端口 ${PROXY_PORT} 已被占用: ${EXISTING}"
    warn "如果是 Squid 服务将被覆盖重启，其他服务请先手动处理"
fi

# ---------- 步骤 2：安装依赖 ----------
info "安装 Squid 和认证工具..."

if dpkg -s squid &>/dev/null && dpkg -s apache2-utils &>/dev/null && command -v curl &>/dev/null; then
    info "Squid、apache2-utils 和 curl 已安装，跳过"
else
    if ! apt-get update -qq; then
        warn "apt-get update 失败，尝试继续安装（可能使用本地缓存）..."
    fi
    apt-get install -y -qq squid apache2-utils curl || error "安装依赖失败"
fi

# ---------- 探测 basic_ncsa_auth 路径 ----------
NCSA_AUTH=""
for _p in /usr/lib/squid/basic_ncsa_auth /usr/lib64/squid/basic_ncsa_auth /usr/lib/squid3/basic_ncsa_auth; do
    if [ -x "$_p" ]; then
        NCSA_AUTH="$_p"
        break
    fi
done
if [ -z "$NCSA_AUTH" ]; then
    NCSA_AUTH=$(dpkg -L squid 2>/dev/null | grep 'basic_ncsa_auth$' | head -1)
fi
[ -x "$NCSA_AUTH" ] || error "找不到 basic_ncsa_auth，请确认 squid 已正确安装"

PASSWD_FILE="/etc/squid/passwd"
if [ "$USER_SPECIFIED" = "true" ] && [ "$PASS_SPECIFIED" = "false" ] && [ -f "$PASSWD_FILE" ] && user_in_passwd "$PROXY_USER" "$PASSWD_FILE"; then
    error "用户 ${PROXY_USER} 已存在，如需更新密码请显式传入 -k"
fi

# ---------- 步骤 3：配置 Squid ----------
info "写入 Squid 配置（端口 ${PROXY_PORT}）..."

SQUID_CONF="/etc/squid/squid.conf"
SQUID_CONF_NEW="${SQUID_CONF}.new"
if [ -f "$SQUID_CONF" ]; then
    cp "$SQUID_CONF" "${SQUID_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    info "已备份当前配置"
fi

cat > "$SQUID_CONF_NEW" <<EOF
http_port ${PROXY_PORT}

auth_param basic program ${NCSA_AUTH} /etc/squid/passwd
auth_param basic realm Proxy Authentication
auth_param basic credentialsttl 5 minutes

# 安全 ACL：限制代理可访问的目标端口和 CONNECT 隧道端口
acl SSL_ports port 443
acl Safe_ports port 80 443 8080 8443
acl CONNECT method CONNECT
acl authenticated proxy_auth REQUIRED

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow authenticated
http_access deny all

# 防滥用超时
request_timeout 5 minutes
connect_timeout 30 seconds

forwarded_for off
via off
request_header_access X-Forwarded-For deny all

cache deny all

httpd_suppress_version_string on
EOF

if [ -n "$DNS_SERVERS" ]; then
    echo "dns_nameservers ${DNS_SERVERS}" >> "$SQUID_CONF_NEW"
fi

# 校验配置语法后再替换
info "校验 Squid 配置语法..."
if ! squid -k parse -f "$SQUID_CONF_NEW" 2>&1; then
    rm -f "$SQUID_CONF_NEW"
    error "Squid 配置语法校验失败，已保留原配置"
fi
mv "$SQUID_CONF_NEW" "$SQUID_CONF"

# ---------- 步骤 4：创建/更新认证用户 ----------
PASS_UNCHANGED=false

if [ ! -f "$PASSWD_FILE" ]; then
    info "创建密码文件并添加用户 ${PROXY_USER}..."
    echo "$PROXY_PASS" | htpasswd -ci "$PASSWD_FILE" "$PROXY_USER"
elif user_in_passwd "$PROXY_USER" "$PASSWD_FILE"; then
    if [ "$PASS_SPECIFIED" = "true" ]; then
        info "更新已有用户 ${PROXY_USER} 的密码..."
        echo "$PROXY_PASS" | htpasswd -i "$PASSWD_FILE" "$PROXY_USER"
    elif [ "$USER_SPECIFIED" = "true" ]; then
        error "用户 ${PROXY_USER} 已存在，如需更新密码请显式传入 -k"
    else
        info "用户 ${PROXY_USER} 已存在，保留原密码"
        PASS_UNCHANGED=true
    fi
else
    info "追加用户 ${PROXY_USER} 到已有密码文件..."
    echo "$PROXY_PASS" | htpasswd -i "$PASSWD_FILE" "$PROXY_USER"
fi

chmod 640 "$PASSWD_FILE"
if id -u squid &>/dev/null; then
    SQUID_USER="squid"
else
    SQUID_USER="proxy"
fi
chown "root:${SQUID_USER}" "$PASSWD_FILE"

# ---------- 步骤 5：部署 proxy-user 管理脚本 ----------
info "部署用户管理工具 proxy-user..."

cat > /usr/local/bin/proxy-user <<'MANAGE_EOF'
#!/bin/bash
PASSWD_FILE="/etc/squid/passwd"
PROXY_PORT=$(grep -m1 '^http_port' /etc/squid/squid.conf 2>/dev/null | awk '{print $2}')
PROXY_PORT=${PROXY_PORT:-38181}
SERVER_IP=$(curl -s4 --max-time 3 ifconfig.me 2>/dev/null) || true
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo "提示: 无法获取公网 IP，使用本机地址 ${SERVER_IP}" >&2
fi

show_usage() {
    echo "用法: proxy-user <命令> [参数]"
    echo ""
    echo "命令:"
    echo "  add    <用户名> [密码]    添加新用户（不提供密码则交互输入）"
    echo "  mod    <用户名> [新密码]  修改用户密码（不提供密码则交互输入）"
    echo "  del    <用户名>           删除用户"
    echo "  list                      列出所有用户"
    echo "  test   <用户名> [密码]    测试用户连接（不提供密码则交互输入）"
}

user_exists() {
    awk -F: -v u="$1" '$1 == u { found=1; exit } END { exit !found }' "$PASSWD_FILE"
}

validate_username() {
    if ! [[ "$1" =~ ^[a-z0-9._-]+$ ]]; then
        echo "错误: 用户名只允许小写字母、数字、点、下划线和连字符"
        exit 1
    fi
}

validate_password() {
    local re='^[A-Za-z0-9._~!*()-]+$'
    if ! [[ "$1" =~ $re ]]; then
        echo "错误: 密码含不安全字符，仅允许: A-Za-z0-9 . _ ~ ! * ( ) -"
        exit 1
    fi
}

read_password() {
    local pass1 pass2
    read -rs -p "请输入密码: " pass1; echo
    [ -z "$pass1" ] && { echo "错误: 密码不能为空"; exit 1; }
    read -rs -p "请再次输入密码: " pass2; echo
    if [ "$pass1" != "$pass2" ]; then
        echo "错误: 两次输入的密码不一致"
        exit 1
    fi
    REPLY_PASS="$pass1"
}

case "$1" in
    add)
        [ -z "$2" ] && { echo "用法: proxy-user add <用户名> [密码]"; exit 1; }
        validate_username "$2"
        if user_exists "$2"; then
            echo "错误: 用户 '$2' 已存在，如需修改密码请用 mod 命令"
            exit 1
        fi
        if [ -n "$3" ]; then
            REPLY_PASS="$3"
        else
            read_password
        fi
        validate_password "$REPLY_PASS"
        echo "$REPLY_PASS" | htpasswd -i "$PASSWD_FILE" "$2"
        echo "代理地址: http://$2:${REPLY_PASS}@${SERVER_IP}:${PROXY_PORT}"
        ;;
    mod)
        [ -z "$2" ] && { echo "用法: proxy-user mod <用户名> [新密码]"; exit 1; }
        validate_username "$2"
        if ! user_exists "$2"; then
            echo "错误: 用户 '$2' 不存在"
            exit 1
        fi
        if [ -n "$3" ]; then
            REPLY_PASS="$3"
        else
            read_password
        fi
        validate_password "$REPLY_PASS"
        echo "$REPLY_PASS" | htpasswd -i "$PASSWD_FILE" "$2"
        echo "代理地址: http://$2:${REPLY_PASS}@${SERVER_IP}:${PROXY_PORT}"
        echo "提示: 密码修改通常在 5 分钟认证缓存窗口内生效，无需重启 Squid"
        ;;
    del)
        [ -z "$2" ] && { echo "用法: proxy-user del <用户名>"; exit 1; }
        if ! user_exists "$2"; then
            echo "错误: 用户 '$2' 不存在"
            exit 1
        fi
        htpasswd -D "$PASSWD_FILE" "$2"
        echo "提示: 用户删除通常在 5 分钟认证缓存窗口内生效，无需重启 Squid"
        ;;
    list)
        if [ ! -s "$PASSWD_FILE" ]; then
            echo "暂无用户"
            exit 0
        fi
        echo "当前用户:"
        awk -F: '{printf "  - %s\t-> http://%s:<密码>@'"${SERVER_IP}:${PROXY_PORT}"'\n", $1, $1}' "$PASSWD_FILE"
        ;;
    test)
        [ -z "$2" ] && { echo "用法: proxy-user test <用户名> [密码]"; exit 1; }
        if [ -n "$3" ]; then
            REPLY_PASS="$3"
        else
            read -rs -p "请输入密码: " REPLY_PASS; echo
            [ -z "$REPLY_PASS" ] && { echo "错误: 密码不能为空"; exit 1; }
        fi
        echo "测试中..."
        for TEST_URL in "http://httpbin.org/ip" "http://ifconfig.me" "http://icanhazip.com"; do
            RESP=$(curl -s -w '\n%{http_code}' --max-time 5 \
                --proxy "http://127.0.0.1:${PROXY_PORT}" \
                --proxy-user "$2:${REPLY_PASS}" \
                "$TEST_URL" 2>/dev/null) || true
            HTTP_CODE=$(echo "$RESP" | tail -1)
            BODY=$(echo "$RESP" | sed '$d')
            if [ "$HTTP_CODE" = "200" ]; then
                echo "连接成功，响应: $BODY"
                exit 0
            fi
        done
        echo "连接失败（HTTP ${HTTP_CODE:-无响应}）"
        exit 1
        ;;
    *)
        show_usage
        ;;
esac
MANAGE_EOF
chmod +x /usr/local/bin/proxy-user

# ---------- 步骤 6：启动服务 ----------
info "启动 Squid 服务..."

if [ -d /run/systemd/system ]; then
    systemctl restart squid
    systemctl enable squid 2>/dev/null

    # ---------- 步骤 7：验证 ----------
    info "验证服务状态..."

    if ! systemctl is-active --quiet squid; then
        error "Squid 启动失败，请检查: journalctl -u squid --no-pager -n 20"
    fi
else
    warn "未检测到 systemd，尝试直接启动 Squid..."
    squid -k reconfigure 2>/dev/null || squid
    sleep 1
fi

if ! ss -tlnp | grep -q ":${PROXY_PORT} "; then
    error "端口 ${PROXY_PORT} 未监听，请检查配置"
fi

SERVER_IP=$(curl -s4 --max-time 3 ifconfig.me 2>/dev/null) || true
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
    warn "无法获取公网 IP，使用本机地址 ${SERVER_IP}（如为内网 IP 请手动替换）"
fi

if [ "$PASS_UNCHANGED" = "true" ]; then
    info "跳过连接测试（用户密码未变更）"
else
    TEST_PASSED=false
    for TEST_URL in "http://httpbin.org/ip" "http://ifconfig.me" "http://icanhazip.com"; do
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            --proxy "http://127.0.0.1:${PROXY_PORT}" \
            --proxy-user "${PROXY_USER}:${PROXY_PASS}" \
            "$TEST_URL" 2>/dev/null) || true
        if [ "$HTTP_CODE" = "200" ]; then
            TEST_PASSED=true
            break
        fi
    done
    if [ "$TEST_PASSED" = "true" ]; then
        info "代理连接测试通过"
    else
        warn "代理连接测试未通过（可能是网络原因，不影响部署）"
    fi
fi

# ---------- 步骤 8：输出结果 ----------
echo ""
echo "================================================"
if [ "$PASS_UNCHANGED" = "true" ]; then
    echo "  HTTP 代理部署完成（已有用户保持不变）"
    echo "================================================"
    echo ""
    echo "  监听端口:  ${PROXY_PORT}"
    echo "  已有用户保持不变，使用 proxy-user list 查看"
else
    echo "  HTTP 代理部署完成"
    echo "================================================"
    echo ""
    echo "  代理地址:  http://${PROXY_USER}:${PROXY_PASS}@${SERVER_IP}:${PROXY_PORT}"
    echo "  监听端口:  ${PROXY_PORT}"
    echo "  用户名:    ${PROXY_USER}"
    echo "  密码:      ${PROXY_PASS}"
    echo ""
    echo "  ** 凭证仅显示一次，请妥善保存 **"
    echo ""
    echo "  使用方式:"
    echo "    export HTTP_PROXY=http://${PROXY_USER}:${PROXY_PASS}@${SERVER_IP}:${PROXY_PORT}"
    echo "    export HTTPS_PROXY=http://${PROXY_USER}:${PROXY_PASS}@${SERVER_IP}:${PROXY_PORT}"
fi
echo ""
echo "  认证缓存:"
echo "    用户改密或删除通常在 5 分钟认证缓存窗口内生效"
echo ""
echo "  用户管理:"
echo "    proxy-user add <用户名> [密码]"
echo "    proxy-user mod <用户名> [新密码]"
echo "    proxy-user del <用户名>"
echo "    proxy-user list"
echo "    proxy-user test <用户名> [密码]"
echo ""
echo "  防火墙提示:"
echo "    若使用 iptables: iptables -I INPUT -p tcp --dport ${PROXY_PORT} -j ACCEPT"
echo "    若使用 ufw:      ufw allow ${PROXY_PORT}/tcp"
echo "    若使用云服务器:   请在安全组中放行 TCP ${PROXY_PORT}"
echo ""
echo "  安全提示:"
echo "    本代理使用 HTTP + Basic Auth，凭证明文传输"
echo "    建议仅在内网/VPN/SSH隧道内使用，或限制源IP访问"
echo "================================================"
