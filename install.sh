#!/bin/sh
# 免责声明：本项目仅供学习与技术研究，请在获得授权的环境中使用。
# 使用者应遵守适用法律法规，并自行承担使用产生的风险；本项目按 LICENSE 原样提供。
# POSIX bootstrap: Alpine/minimal images may not have Bash yet.
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        case "${1:-}" in
            -h|--help|help) printf '%s\n' '用法: sh install.sh [install|add|delete|list|links|status|check|start|stop|restart|update|cert|outbound|bbr|uninstall] [选项]' '运行命令时会自动安装 Bash；完整参数说明见 README.md。'; exit 0 ;;
        esac
        bootstrap_skip_value=0
        for bootstrap_arg do
            if [ "$bootstrap_skip_value" = 1 ]; then bootstrap_skip_value=0; continue; fi
            case "$bootstrap_arg" in
                doctor|status|logs) echo '[错误] 只读查看需要 Bash 4 或更高版本，请先自行安装 Bash。' >&2; exit 3 ;;
                --protocol|--tag|--port|--uuid|--password|--password-file|--tunnel-token-file|--cf-token-file|--cert|--method|--sni|--sni-region|--sni-category|--sni-hosts|--sni-jobs|--sni-samples|--sni-timeout|--domain|--version|--validation|--address|--edge|--strategy|--firewall|--lines|--source) bootstrap_skip_value=1 ;;
                -*) ;;
                *) break ;;
            esac
        done
        [ "$(uname -s)" = Linux ] || { echo '[错误] 仅支持 Linux。' >&2; exit 3; }
        [ "$(id -u)" = 0 ] || { echo '[错误] 安装 Bash 需要 root，请使用 sudo sh install.sh ...。' >&2; exit 3; }
        [ -f "$0" ] || { echo '[错误] 请先将脚本下载到文件，再用 sh install.sh 执行。' >&2; exit 2; }
        echo '[信息] 缺少 Bash，正在自动安装。' >&2
        if command -v apk >/dev/null 2>&1; then apk add --no-cache bash ca-certificates
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash ca-certificates
        elif command -v dnf >/dev/null 2>&1; then dnf install -y bash ca-certificates
        elif command -v yum >/dev/null 2>&1; then yum install -y bash ca-certificates
        elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install bash ca-certificates
        elif command -v pacman >/dev/null 2>&1; then pacman -Syu --noconfirm --needed bash ca-certificates
        else echo '[错误] 不支持的包管理器，无法自动安装 Bash。' >&2; exit 3
        fi
        [ "$?" = 0 ] && command -v bash >/dev/null 2>&1 || { echo '[错误] Bash 安装失败，请检查软件源和网络。' >&2; exit 1; }
    fi
    exec bash "$0" "$@"
fi

[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo '[错误] 需要 Bash 4 或更高版本。' >&2; exit 3; }

umask 077

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

if [ ! -t 1 ] || [ "${TERM:-dumb}" = dumb ] || [ -n "${NO_COLOR:-}" ]; then
    RED='' GREEN='' YELLOW='' CYAN='' PLAIN=''
fi
CONFIG_DIR="/etc/onebox"
CONFIG_FILE="$CONFIG_DIR/config.json"
CERT_DIR="$CONFIG_DIR/cert"
SECRETS_FILE="$CONFIG_DIR/.secrets"
FW_PORTS_FILE="$CONFIG_DIR/.fw_ports"
ACME_HOME="/var/lib/onebox/acme"

KERNEL_TMP_DIR=""
declare -a SB_OWNED_TEMP_FILES=()
declare -a SB_OWNED_TEMP_DIRS=()

SB_SNI_PID=""
run_step() {
    local label="$1" log rc=0
    shift
    mkdir -p /var/log/onebox && chmod 700 /var/log/onebox || return 1
    log=$(mktemp /var/log/onebox/step.XXXXXX) || return 1
    chmod 600 "$log" || { rm -f "$log"; return 1; }
    # Keep installation transactions free of background animation jobs and their waits.
    printf '[进行中] %s\n' "$label" >&2
    if "$@" >"$log" 2>&1; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 0 ]; then
        printf '[完成] %s\n' "$label" >&2
        rm -f "$log"
    else
        printf '[失败] %s（退出码 %s）\n日志：%s\n' "$label" "$rc" "$log" >&2
        printf '[诊断] Bash %s；系统架构 %s；包管理器 %s。\n' "$BASH_VERSION" "${ARCH:-未知}" "${PACKAGE_MANAGER:-未知}" >&2
        tail -n 15 "$log" >&2
    fi
    return "$rc"
}

cleanup_on_exit() {
    stop_sni_selection
    if [ -n "${CONFIG_TX_DIR:-}" ] && [ "${CONFIG_TX_RECOVERING:-0}" != 1 ]; then
        CONFIG_TX_RECOVERING=1
        restore_config_and_service || printf '事务恢复失败，备份保留: %s\n' "$CONFIG_TX_DIR" >&2
    fi
    [ -n "$KERNEL_TMP_DIR" ] && rm -rf "$KERNEL_TMP_DIR" 2>/dev/null
    local owned_temp
    for owned_temp in "${SB_OWNED_TEMP_FILES[@]}"; do
        [ -n "$owned_temp" ] && rm -f -- "$owned_temp" 2>/dev/null
    done
    for owned_temp in "${SB_OWNED_TEMP_DIRS[@]}"; do
        [ -n "$owned_temp" ] && rm -rf -- "$owned_temp" 2>/dev/null
    done
    return 0
}
cleanup_on_interrupt() {
    echo -e "\n${RED}[INFO] 接收到中断信号 (Ctrl+C)，正在清理临时文件并彻底退出...${PLAIN}" >&2
    cleanup_on_exit
    exit 130
}
NON_INTERACTIVE=0
ASSUME_YES=0
SERVICE_MANAGER=""
PACKAGE_MANAGER=""

die() { printf '[错误] %s\n' "$1" >&2; exit "${2:-1}"; }

detect_environment() {
    [ "$(uname -s)" = Linux ] || die '仅支持 Linux。' 3
    [ "$EUID" = 0 ] || die '请以 root 身份运行（sudo sh install.sh ...）。' 3
    local pm
    for pm in apk apt-get dnf yum zypper pacman; do
        if command -v "$pm" >/dev/null 2>&1; then PACKAGE_MANAGER="$pm"; break; fi
    done
    [ -n "$PACKAGE_MANAGER" ] || die '不支持的包管理器；支持 apk、apt-get、dnf、yum、zypper、pacman。' 3
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) SB_ARCH=amd64; CF_ARCH=amd64 ;;
        aarch64|arm64) SB_ARCH=arm64; CF_ARCH=arm64 ;;
        i386|i486|i586|i686) SB_ARCH=386; CF_ARCH=386 ;;
        armv7l|armv7*) SB_ARCH=armv7; CF_ARCH=arm ;;
        armv6l|armv6*) SB_ARCH=armv6; CF_ARCH=arm ;;
        riscv64|s390x|ppc64le) SB_ARCH="$ARCH"; CF_ARCH="" ;;
        *) die "不支持的系统架构：$ARCH。" 3 ;;
    esac
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 &&
       systemctl show --property=Version --value >/dev/null 2>&1; then
        SERVICE_MANAGER=systemd
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 &&
         [ -f /run/openrc/softlevel ]; then
        SERVICE_MANAGER=openrc
    else
        die '未检测到正在运行的 systemd 或 OpenRC。无 init 的 Docker/WSL、SysVinit、runit 等环境不支持服务管理。' 3
    fi
}

GLOBAL_IP=""
IP_LOOKUP_SKIPPED=0
GLOBAL_LATEST_VER=""
KERNEL_REINSTALLED=0

ask() {
    local __prompt="$1"
    local __var="$2"
    local __val
    if [ "$NON_INTERACTIVE" = 1 ]; then
        case "$__var" in
            proto_idx) __val="$CLI_PROTOCOL_INDEX" ;;
            PORT) __val="${CLI_PORT:-}" ;;
            input_tag) __val="${CLI_TAG:-}" ;;
            c_idx) case "$CLI_CERT" in self) __val=2 ;; real) __val=1 ;; esac ;;
            ARGO_TOKEN) __val="${CLI_TUNNEL_TOKEN:-}" ;;
            PASS) __val="${CLI_PASSWORD:-}" ;;
            auto_fw) __val="$CLI_FIREWALL" ;;
            ru) __val=y ;;
            v_mode) case "$CLI_VALIDATION" in http) __val=1 ;; dns) __val=2 ;; esac ;;
            NEW_CF_Key) __val="${CF_Key:-}" ;;
            NEW_CF_Email) __val="${CF_Email:-}" ;;
            confirmed) [ "$CLI_HTTP01_READY" = 1 ] || die 'HTTP-01 需要显式指定 --http01-ready。' 2; __val=y ;;
            un) [ "$ASSUME_YES" = 1 ] || die '无交互卸载必须指定 --yes。' 2; __val=y ;;
            reply) [ "$CLI_RESTORE_BBR" = 1 ] && __val=y || __val=n ;;
            rebuild) die '配置损坏，请先备份并手动修复；无交互模式不会清空现有节点。' ;;
            *) die "无交互操作缺少参数或遇到未支持的提示：$__prompt" 2 ;;
        esac
        printf -v "$__var" '%s' "$__val"
        return 0
    fi
    local __secret=0
    case "$__prompt" in *密码*|*Token*|*API\ Key*) __secret=1 ;; esac
    if [ "$__secret" = 1 ]; then
        IFS= read -r -s -p "$__prompt" __val; local __rc=$?; printf '\n' >&2
    else
        IFS= read -r -p "$__prompt" __val; local __rc=$?
    fi
    if [ "$__rc" != 0 ]; then
        echo -e "\n${RED}输入流已结束(检测到 EOF)，无法继续交互。${PLAIN}" >&2
        echo -e "${YELLOW}如果您是用管道方式运行(例如 curl ... | bash)，请改为:${PLAIN}" >&2
        echo -e "${YELLOW}  先下载再执行，或执行 onebox 命令进入面板。${PLAIN}" >&2
        exit 1
    fi
    printf -v "$__var" '%s' "$__val"
}

pause() {
    [ "$NON_INTERACTIVE" = 0 ] || return 0
    while read -r -t 0.1; do :; done
    echo ""
    ask "按回车键继续..." _PAUSE_DUMMY
}

lookup_public_ip_endpoint() {
    # Viewing a node must not inherit wget retries or wait on a failing proxy.
    # Prefer one downloader per endpoint and keep the entire request bounded.
    if command -v curl >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout -k 1 3 curl -q --noproxy '*' -fsS --connect-timeout 1 --max-time 2 --retry 0 "$1" 2>/dev/null
        else
            curl -q --noproxy '*' -fsS --connect-timeout 1 --max-time 2 --retry 0 "$1" 2>/dev/null
        fi
    elif command -v timeout >/dev/null 2>&1 && command -v wget >/dev/null 2>&1; then
        timeout -k 1 3 wget -T 2 -qO - "$1" 2>/dev/null
    else
        return 1
    fi
}

get_ip() {
    IP_LOOKUP_SKIPPED=0
    if [ -n "${CLI_ADDRESS:-}" ]; then GLOBAL_IP="$CLI_ADDRESS"; return 0; fi
    if [ -z "$GLOBAL_IP" ]; then
        local IP_CACHE="$CONFIG_DIR/.ip_cache"
        local IP_TTL=300 c_time='' c_ip='' now=''
        local valid_cache_ip=0
        # Read the tiny cache with Bash builtins so a full cgroup PID budget
        # does not trigger several failing forks before we can show node data.
        if [ -r "$IP_CACHE" ]; then
            { IFS= read -r c_time || :; IFS= read -r c_ip || :; } < "$IP_CACHE"
            if [[ "$c_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] ||
               [[ "$c_ip" == *:* && "$c_ip" =~ ^[0-9a-fA-F:]+$ ]]; then
                valid_cache_ip=1
            fi
        fi

        # The probe reads procfs/cgroup files using shell builtins. Leave room
        # for the command-substitution shell, timeout, and curl before trying
        # the network; Bash may otherwise retry a failed fork indefinitely.
        onebox_probe_pids_budget
        local pid_headroom="$sni_pid_headroom" pid_source="$sni_pid_source"

        # Bash's printf time format avoids forking date just to validate a cache.
        printf -v now '%(%s)T' -1 2>/dev/null || now=''
        # Bash 4.0/4.1 lack printf's %T format; use date only when there is
        # enough process headroom to do so safely.
        if [ -z "$now" ] && { [ "$pid_headroom" -lt 0 ] || [ "$pid_headroom" -ge 8 ]; }; then
            now=$(date +%s 2>/dev/null)
        fi
        if [ "$valid_cache_ip" = 1 ] && [[ "$c_time" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] &&
           [ "$c_time" -le "$now" ] && [ $((now-c_time)) -le "$IP_TTL" ]; then
            GLOBAL_IP="$c_ip"
            return 0
        fi

        if [ "$pid_headroom" -ge 0 ] && [ "$pid_headroom" -lt 8 ]; then
            IP_LOOKUP_SKIPPED=1
            printf '[提示] 剩余进程额度不足（%s），已跳过公网 IP 查询；节点详情仍会显示，分享链接请稍后重试或用 --address 指定。\n' \
                "$pid_source" >&2
            return 1
        fi

        printf '[信息] 正在查询公网地址（超时后可用 onebox links --address 手动指定）...\n' >&2
        local ip
        ip=$(lookup_public_ip_endpoint https://ipv4.icanhazip.com)
        if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            GLOBAL_IP="$ip"
        else
            ip=$(lookup_public_ip_endpoint https://ipv6.icanhazip.com)
            if [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
                GLOBAL_IP="$ip"
            fi
        fi

        if [ -n "$GLOBAL_IP" ]; then
            # CONFIG_DIR normally exists already; create it only on a
            # successful lookup, and rely on the script's umask 077.
            [ -d "$CONFIG_DIR" ] || mkdir -p "$CONFIG_DIR" 2>/dev/null || :
            printf -v now '%(%s)T' -1 2>/dev/null || now=''
            if [ -z "$now" ] && { [ "$pid_headroom" -lt 0 ] || [ "$pid_headroom" -ge 8 ]; }; then
                now=$(date +%s 2>/dev/null)
            fi
            if [[ "$now" =~ ^[0-9]+$ ]]; then
                printf '%s\n%s\n' "$now" "$GLOBAL_IP" > "$IP_CACHE" 2>/dev/null || :
            fi
        fi
    fi
    [ -n "$GLOBAL_IP" ] || { printf '[提示] 未查到公网 IP；节点配置仍可查看，分享链接请用 --address 指定。\n' >&2; return 1; }
    return 0
}

get_latest_version() {
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    local CACHE_FILE="$CONFIG_DIR/.version_cache"
    [ -f "$CACHE_FILE" ] && chmod 600 "$CACHE_FILE" 2>/dev/null

    local CACHE_TTL=3600
    local NOW
    NOW=$(date +%s)

    if [ -z "$GLOBAL_LATEST_VER" ]; then
        if [ -f "$CACHE_FILE" ]; then
            local CACHE_TIME
            CACHE_TIME=$(head -n 1 "$CACHE_FILE" 2>/dev/null)
            local CACHE_VER
            CACHE_VER=$(tail -n 1 "$CACHE_FILE" 2>/dev/null)
            if [[ "$CACHE_TIME" =~ ^[0-9]+$ ]] && [ $((NOW - CACHE_TIME)) -le $CACHE_TTL ] && [ -n "$CACHE_VER" ]; then
                GLOBAL_LATEST_VER="$CACHE_VER"
                echo "$GLOBAL_LATEST_VER"
                return
            fi
        fi

        local res
        res=$(http_get "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
              | grep '"tag_name":' \
              | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
              | head -n 1)
        if [[ "$res" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            GLOBAL_LATEST_VER=${res#v}
            echo "$NOW" > "$CACHE_FILE"
            echo "$GLOBAL_LATEST_VER" >> "$CACHE_FILE"
            chmod 600 "$CACHE_FILE" 2>/dev/null
        fi
    fi
    echo "$GLOBAL_LATEST_VER"
}

JQ_DNS_LOCAL='.dns.servers |= (. // []) |
  if (.dns.servers | map(select(.tag == "dns-local")) | length == 0) then
    .dns.servers += [{"tag": "dns-local", "type": "local"}]
  else . end'

sb_bin_ge_112() {
    local bin="${1:-/usr/local/lib/onebox/sing-box}"
    local ver
    ver=$( ( "$bin" version ) 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    [ -z "$ver" ] && return 1
    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    [[ "$major" =~ ^[0-9]+$ ]] && [[ "$minor" =~ ^[0-9]+$ ]] || return 1
    [ "$major" -gt 1 ] && return 0
    { [ "$major" -eq 1 ] && [ "$minor" -ge 12 ]; } && return 0
    return 1
}

sb_ge_112() {
    sb_bin_ge_112 "/usr/local/lib/onebox/sing-box"
}

upgrade_config_schema() {
    local target_file="${1:-$CONFIG_FILE}"
    local is_112="${2:-0}"
    [ -f "$target_file" ] || return 0
    local tmp
    tmp=$(mktemp "${target_file}.upg.XXXXXX") || return 1
    SB_OWNED_TEMP_FILES+=("$tmp")
    cp -p "$target_file" "$tmp" || { rm -f "$tmp"; return 1; }

    local filter='(.route.rules[]? | select(has("geoip") and .geoip == "private")) |= (del(.geoip) | .ip_is_private = true) |
      if ((.outbounds? // []) | map(select(.tag=="direct")) | length) == 0 then
        .outbounds = ((.outbounds // []) + [{"type":"direct","tag":"direct"}])
      else . end'

    if [ "$is_112" -eq 1 ]; then
        filter="$filter |
          (.route.rules[]? | select(.outbound==\"block\")) |= (del(.outbound) | .action=\"reject\") |
          .outbounds |= map(select(.type!=\"block\")) |
          if (([.outbounds[]? | select(has(\"domain_strategy\") or has(\"domain_resolver\"))] | length) > 0) then
            $JQ_DNS_LOCAL |
            (.outbounds[] | select(has(\"domain_strategy\"))) |= (.domain_resolver = {\"server\": \"dns-local\", \"strategy\": .domain_strategy} | del(.domain_strategy)) |
            (.outbounds[] | select(has(\"domain_resolver\"))) |= (if (.domain_resolver | type) == \"object\" then (if .domain_resolver.server == null or .domain_resolver.server == \"\" then .domain_resolver.server = \"dns-local\" else . end) else . end)
          else . end"
    fi

    if jq "$filter" "$target_file" > "$tmp" &&
       jq -e 'type == "object" and (.inbounds | type == "array")' "$tmp" >/dev/null &&
       chmod 600 "$tmp" && mv -f "$tmp" "$target_file"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

check_port_in_config() {
    local port="$1"
    local proto="${2:-both}"
    local exclude_tag="${3:-}"
    [ -f "$CONFIG_FILE" ] || return 1
    local existing
    existing=$(jq -r --argjson p "$port" --arg ex "$exclude_tag" '
      .inbounds[]?
      | select(.listen_port == $p and .tag != $ex)
      | "\(.type)|\(if .transport.type == "ws" then "ws" else "" end)"
    ' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$existing" ] && return 1
    local e_type _e_ws e_proto
    while IFS='|' read -r e_type _e_ws; do
        [ -z "$e_type" ] && continue
        case "$e_type" in
            hysteria2|tuic) e_proto="udp" ;;
            anytls|vless)   e_proto="tcp" ;;
            shadowsocks)    e_proto="both" ;;
            *)              e_proto="both" ;;
        esac
        if [ "$proto" = "both" ] || [ "$e_proto" = "both" ] || [ "$proto" = "$e_proto" ]; then
            return 0
        fi
    done <<< "$existing"
    return 1
}

check_port() {
    local port=$1
    local proto=${2:-both}
    local exclude_tag=${3:-}
    if check_port_in_config "$port" "$proto" "$exclude_tag"; then
        return 0
    fi
    local ss_arg="-tuln"
    [ "$proto" == "tcp" ] && ss_arg="-tln"
    [ "$proto" == "udp" ] && ss_arg="-uln"

    local listeners
    if command -v ss >/dev/null 2>&1; then
        listeners=$(ss "$ss_arg" 2>/dev/null) || { echo '[错误] 无法读取监听端口。' >&2; return 0; }
    else
        echo '[错误] 缺少 ss，无法确认端口空闲。' >&2
        return 0
    fi
    printf '%s\n' "$listeners" | grep -qE "[^[:space:]]:${port}([[:space:]]|$)"
}

rand_port() {
    local port attempt
    for ((attempt=0; attempt<100; attempt++)); do
        port=$(( ( (RANDOM << 15) | RANDOM ) % 55001 + 10000 ))
        if ! check_port "$port" both; then printf '%s\n' "$port"; return 0; fi
    done
    printf '[错误] 无法找到空闲端口。\n' >&2
    return 1
}

url_encode() {
    jq -rn --arg s "$1" '$s|@uri'
}

wrap_ipv6() {
    local ip=$1
    if [[ "$ip" == *":"* ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}

save_secret() {
    local key=$1
    local val=$2
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    [[ "$val" != *$'\n'* && "$val" != *$'\r'* && "$val" != *"'"* ]] || {
        printf '%s\n' 'secrets 值包含不支持的换行或单引号，未写入。' >&2
        return 1
    }
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    touch "$SECRETS_FILE" || return 1
    local tmp
    tmp=$(mktemp "${SECRETS_FILE}.tmp.XXXXXX") || return 1
    SB_OWNED_TEMP_FILES+=("$tmp")
    grep -v "^${key}=" "$SECRETS_FILE" > "$tmp" 2>/dev/null
    local rc=$?
    if [ "$rc" -le 1 ] && echo "${key}='${val}'" >> "$tmp"; then
        if chmod 600 "$tmp" && mv -f "$tmp" "$SECRETS_FILE"; then return 0; fi
        rm -f "$tmp"
        printf '%s\n' 'secrets 原子替换失败。' >&2
        return 1
    fi
    rm -f "$tmp"
    echo -e "${RED}[错误] 写入 secrets 失败，已保留原文件！${PLAIN}" >&2
    return 1
}

remove_secret() {
    local key="$1" tmp rc
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    [ -f "$SECRETS_FILE" ] || return 0
    tmp=$(mktemp "${SECRETS_FILE}.tmp.XXXXXX") || return 1
    SB_OWNED_TEMP_FILES+=("$tmp")
    grep -v "^${key}=" "$SECRETS_FILE" > "$tmp"
    rc=$?
    if [ "$rc" -le 1 ] && chmod 600 "$tmp" && mv -f "$tmp" "$SECRETS_FILE"; then return 0; fi
    rm -f "$tmp"
    return 1
}

load_secrets() {
    local line key val
    for key in $(compgen -A variable); do
        case "$key" in
            REAL_DOMAIN|SELF_DOMAIN|REAL_CERT_OWNED|INSTALLER_SRC|CERT_TYPE|DOMAIN|ARGO_SERVICES) unset "$key" || return 1 ;;
            REALITY_PUB_*|ARGO_IP_*|ARGO_DOMAIN_*)
                [[ "$key" =~ ^(REALITY_PUB|ARGO_IP|ARGO_DOMAIN)_[0-9]+$ ]] && { unset "$key" || return 1; } ;;
        esac
    done
    [ -f "$SECRETS_FILE" ] || return 0
    [ -r "$SECRETS_FILE" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=\'(.*)\'$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        case "$key" in
            REAL_DOMAIN|SELF_DOMAIN|REAL_CERT_OWNED|INSTALLER_SRC|CERT_TYPE|DOMAIN|ARGO_SERVICES) ;;
            *) [[ "$key" =~ ^(REALITY_PUB|ARGO_IP|ARGO_DOMAIN)_[0-9]+$ ]] || continue ;;
        esac
        printf -v "$key" '%s' "$val" || return 1
    done < "$SECRETS_FILE"
    return 0
}

apply_jq_config() {
    local filter="$1" tmp
    shift
    tmp=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX") || return 1
    SB_OWNED_TEMP_FILES+=("$tmp")
    if jq "$@" "$filter" "$CONFIG_FILE" > "$tmp" &&
       jq -e 'type == "object" and (.inbounds | type == "array")' "$tmp" >/dev/null &&
       chmod 600 "$tmp" && mv -f "$tmp" "$CONFIG_FILE"; then
        return 0
    fi
    rm -f "$tmp"
    printf '%s\n' '配置生成或写入失败，原文件未主动删除。' >&2
    return 1
}

http_get() {
    local url="$1" body
    if command -v curl >/dev/null 2>&1; then
        if body=$(curl -fsSL --connect-timeout 5 --max-time 10 "$url" 2>/dev/null); then
            printf '%s' "$body"
            return 0
        fi
    fi
    if command -v wget >/dev/null 2>&1; then
        if body=$(wget -T 10 -qO - "$url" 2>/dev/null); then
            printf '%s' "$body"
            return 0
        fi
    fi
    return 1
}

copy_or_fetch_script() {
    local installer="$1" target="$2"
    if [ -n "$installer" ] && [[ "$installer" != /dev/* ]] && [ -f "$installer" ]; then
        cp -- "$installer" "$target"
    else
        fetch_url "https://raw.githubusercontent.com/liuarui/onebox/main/install.sh" "$target"
    fi
}
valid_script_file() {
    local script="$1"
    [ -s "$script" ] \
        && head -n 1 "$script" | grep -q '^#!/bin/sh' \
        && tail -n 5 "$script" | grep -q '^# ONEBOX_ENTRYPOINT$' \
        && grep -q '^install_kernel() {' "$script" \
        && grep -q '^add_config() {' "$script" \
        && bash -n "$script" 2>/dev/null
}

prepare_script_path() {
    local source="$1" dir
    case "$source" in
        /dev/fd/*|/proc/*/fd/*|/dev/stdin)
            # Process substitution is a consumed stream; fetch a reusable file
            # for the flock child and the installed onebox command.
            ensure_deps curl || return 1
            dir=$(mktemp -d /tmp/onebox-bootstrap.XXXXXX) || return 1
            SB_OWNED_TEMP_DIRS+=("$dir")
            ONEBOX_SELF="$dir/install.sh"
            if ! copy_or_fetch_script "" "$ONEBOX_SELF" || ! valid_script_file "$ONEBOX_SELF"; then
                printf '[错误] 无法下载或校验启动脚本，请检查 GitHub Raw 连接后重试。\n' >&2
                return 1
            fi ;;
        *)
            ONEBOX_SELF=$(readlink -f -- "$source") || return 1
            if [ ! -f "$ONEBOX_SELF" ] || [ ! -r "$ONEBOX_SELF" ]; then
                printf '[错误] 无法读取脚本文件：%s\n' "$source" >&2
                return 1
            fi ;;
    esac
}

fetch_script() {
    local t
    local installer="${1:-}"
    mkdir -p /usr/local/bin || return 1
    t=$(mktemp /usr/local/bin/.onebox.XXXXXX) || return 1
    SB_OWNED_TEMP_FILES+=("$t")
    if copy_or_fetch_script "$installer" "$t" && valid_script_file "$t"; then
        if chmod 755 "$t" && mv -f "$t" /usr/local/bin/onebox; then
            return 0
        fi
        rm -f "$t"
        printf '%s\n' '脚本写入失败，未完成更新。' >&2
        return 1
    fi
    rm -f "$t"
    return 1
}

register_argo_service() {
    local svc="$1"
    [[ "$svc" =~ ^cloudflared-[a-zA-Z0-9_-]+$ ]] || return 1
    load_secrets || return 1
    case ",${ARGO_SERVICES:-}," in
        *",$svc,"*) return 0 ;;
    esac
    local updated="${ARGO_SERVICES:+${ARGO_SERVICES},}${svc}"
    save_secret ARGO_SERVICES "$updated" || return 1
    ARGO_SERVICES="$updated"
}

unregister_argo_service() {
    local target="$1" svc updated=""
    local -a registered=()
    [[ "$target" =~ ^cloudflared-[A-Za-z0-9_-]+$ ]] || return 1
    load_secrets || return 1
    [ -n "${ARGO_SERVICES:-}" ] || return 0
    IFS=',' read -r -a registered <<< "$ARGO_SERVICES"
    for svc in "${registered[@]}"; do
        [ -n "$svc" ] || continue
        [ "$svc" = "$target" ] && continue
        updated="${updated:+${updated},}${svc}"
    done
    if [ -n "$updated" ]; then
        save_secret ARGO_SERVICES "$updated" || return 1
        ARGO_SERVICES="$updated"
    else
        remove_secret ARGO_SERVICES || return 1
        unset ARGO_SERVICES
    fi
    return 0
}

cleanup_node_secrets() {
    local port="$1" type="$2" is_argo="${3:-0}"
    if [ "$is_argo" -eq 1 ]; then
        remove_secret "ARGO_IP_${port}" || return 1
        remove_secret "ARGO_DOMAIN_${port}" || return 1
    elif [ "$type" == "vless" ]; then
        remove_secret "REALITY_PUB_${port}" || return 1
    fi
    return 0
}

record_fw_port() {
    local port="$1" proto="$2" tmp_fw
    tmp_fw=$(mktemp "${FW_PORTS_FILE}.tmp.XXXXXX") || return 1
    SB_OWNED_TEMP_FILES+=("$tmp_fw")
    if ! ( if [ -f "$FW_PORTS_FILE" ]; then cat "$FW_PORTS_FILE" || return 1; fi; printf '%s/%s\n' "$port" "$proto" ) > "$tmp_fw"; then
        rm -f "$tmp_fw"; return 1
    fi
    if sort -u -o "$tmp_fw" "$tmp_fw" && chmod 600 "$tmp_fw" && mv -f "$tmp_fw" "$FW_PORTS_FILE"; then return 0; fi
    rm -f "$tmp_fw"
    return 1
}

iptables_rule_state() {
    local tool="$1" port="$2" proto="$3" rc=0 rules listed=0
    "$tool" -C INPUT -p "$proto" --dport "$port" -m comment --comment onebox -j ACCEPT >/dev/null 2>&1 || rc=$?
    case "$rc" in 0) return 0 ;; 1) ;; *) return 2 ;; esac
    # Exit 1 can also mean an operational error. Confirm absence using a readable
    # chain; a matching listed rule makes the failed check inconclusive.
    rules=$("$tool" -S INPUT 2>/dev/null) || return 2
    printf '%s\n' "$rules" | awk -v port="$port" -v proto="$proto" '
      { p=""; d=""; c=""
        for (i=1; i<NF; i++) {
          if ($i=="-p" || $i=="--protocol") p=$(i+1)
          if ($i=="--dport" || $i=="--destination-port") d=$(i+1)
          if ($i=="--comment") { c=$(i+1); gsub(/[\047\042]/,"",c) }
        }
        if ((p==proto || (proto=="tcp" && p=="6") || (proto=="udp" && p=="17")) && d==port && c=="onebox") found=1
      }
      END { exit !found }' || listed=$?
    [ "$listed" = 1 ] || return 2
    return 1
}

open_fw_port() {
    local port=$1
    local proto=$2
    if [ "$proto" == "both" ]; then
        open_fw_port "$port" "tcp" || return 1
        open_fw_port "$port" "udp" || return 1
        return 0
    fi
    local success=0 fw_recorded=0 ufw_active=0 ufw_status=""
    local fw_found=0

    if command -v ufw >/dev/null 2>&1; then
        ufw_status=$(LC_ALL=C ufw status 2>/dev/null) || {
            printf '[错误] 无法读取 ufw 状态，取消修改防火墙。\n' >&2; return 1;
        }
        if printf '%s\n' "$ufw_status" | grep -q '^Status: active$'; then ufw_active=1; fi
    fi
    if [ "$ufw_active" = 1 ]; then
        fw_found=1
        if printf '%s\n' "$ufw_status" | awk -v p="$port/$proto" '$1 == p && ($2 == "ALLOW" || ($2 == "(v6)" && $3 == "ALLOW")) {found=1} END {exit !found}'; then return 0; fi
        record_fw_port "$port" "$proto" || return 1
        fw_recorded=1
        if ufw allow "${port}"/"${proto}" comment 'onebox' >/dev/null 2>&1; then
            success=1
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        fw_found=1
        local permanent_rc=0 runtime_rc=0
        firewall-cmd --query-port="$port/$proto" --permanent >/dev/null 2>&1 || permanent_rc=$?
        firewall-cmd --query-port="$port/$proto" >/dev/null 2>&1 || runtime_rc=$?
        [ "$permanent_rc" -le 1 ] && [ "$runtime_rc" -le 1 ] || return 1
        if [ "$permanent_rc" = 0 ]; then
            # Keep pre-existing administrator rules; activate the saved rule
            # directly without reloading unrelated firewalld runtime changes.
            if [ "$runtime_rc" != 0 ]; then
                firewall-cmd --add-port="$port/$proto" >/dev/null 2>&1 || return 1
                firewall-cmd --query-port="$port/$proto" >/dev/null 2>&1 || return 1
            fi
            return 0
        elif [ "$runtime_rc" = 0 ]; then
            printf '[提示] 复用现有 firewalld 临时规则 %s/%s；重载或重启后可能失效，请自行持久化。\n' "$port" "$proto" >&2
            return 0
        fi
        # Record ownership before changing either scope so partial failures
        # remain recoverable by uninstall. Both scopes were absent above.
        record_fw_port "$port" "$proto" || return 1
        fw_recorded=1
        if firewall-cmd --add-port="$port/$proto" --permanent >/dev/null 2>&1 &&
           firewall-cmd --add-port="$port/$proto" >/dev/null 2>&1 &&
           firewall-cmd --query-port="$port/$proto" --permanent >/dev/null 2>&1 &&
           firewall-cmd --query-port="$port/$proto" >/dev/null 2>&1; then success=1; fi
    elif command -v iptables >/dev/null 2>&1; then
        fw_found=1
        record_fw_port "$port" "$proto" || return 1
        fw_recorded=1
        success=1
        local tool query_rc
        for tool in iptables ip6tables; do
            command -v "$tool" >/dev/null 2>&1 || continue
            query_rc=0
            iptables_rule_state "$tool" "$port" "$proto" || query_rc=$?
            case "$query_rc" in
                0) ;;
                1) "$tool" -I INPUT -p "$proto" --dport "$port" -m comment --comment onebox -j ACCEPT >/dev/null 2>&1 || success=0 ;;
                *) printf '[错误] 无法确认 %s 规则状态；保留端口记录。\n' "$tool" >&2; return 1 ;;
            esac
            [ "$success" = 1 ] || break
        done
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || echo '[提示] 防火墙规则已添加，但持久化失败；规则记录将保留。' >&2
        else
            echo '[提示] iptables 规则仅在当前运行期生效；请配置本机防火墙持久化。' >&2
        fi
    fi

    if [ "$fw_found" -eq 1 ] && [ "$success" -eq 1 ]; then
        [ "$fw_recorded" = 1 ] || record_fw_port "$port" "$proto" || return 1
        echo -e "${GREEN}[完成] 放行端口 ${port}/${proto} 成功${PLAIN}" >&2
    elif [ "$fw_found" -eq 0 ]; then
        echo -e "${YELLOW}[提示] 未检测到系统内置防火墙工具，请确保云服务商后台和本机系统放行了 ${port} 端口！${PLAIN}" >&2
    else
        printf '放行端口 %s/%s 失败。\n' "$port" "$proto" >&2
        return 1
    fi
    return 0
}

close_fw_port() {
    local port=$1
    local proto=$2
    if [ "$proto" == "both" ]; then
        local failed=0
        close_fw_port "$port" "tcp" || failed=1
        close_fw_port "$port" "udp" || failed=1
        return "$failed"
    fi

    # A rule belonging to another node or administrator must not be removed.
    if [ "${UNINSTALLING:-0}" != 1 ]; then check_port_in_config "$port" "$proto" && return 0; fi
    [ -f "$FW_PORTS_FILE" ] && grep -Fxq "$port/$proto" "$FW_PORTS_FILE" || return 0
    local ufw_active=0 ufw_status=""
    if command -v ufw >/dev/null 2>&1; then
        ufw_status=$(LC_ALL=C ufw status 2>/dev/null) || {
            printf '[错误] 无法读取 ufw 状态；保留端口记录。\n' >&2; return 1;
        }
        if printf '%s\n' "$ufw_status" | grep -q '^Status: active$'; then ufw_active=1; fi
    fi
    if [ "$ufw_active" = 1 ]; then
        if printf '%s\n' "$ufw_status" | awk -v p="$port/$proto" '$1 == p && ($2 == "ALLOW" || ($2 == "(v6)" && $3 == "ALLOW")) && /# onebox([[:space:]]|$)/ {found=1} END {exit !found}'; then
            ufw delete allow "${port}"/"${proto}" >/dev/null 2>&1 || return 1
            ufw_status=$(LC_ALL=C ufw status 2>/dev/null) || return 1
            printf '%s\n' "$ufw_status" | grep -q '^Status: active$' || return 1
            if printf '%s\n' "$ufw_status" | awk -v p="$port/$proto" '$1 == p && ($2 == "ALLOW" || ($2 == "(v6)" && $3 == "ALLOW")) && /# onebox([[:space:]]|$)/ {found=1} END {exit !found}'; then return 1; fi
        else
            printf '[提示] 未确认 ufw 规则归属，保留 %s/%s。\n' "$port" "$proto" >&2
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        local scope query_rc
        for scope in permanent runtime; do
            local -a scope_args=()
            [ "$scope" != permanent ] || scope_args+=(--permanent)
            query_rc=0
            firewall-cmd --query-port="$port/$proto" "${scope_args[@]}" >/dev/null 2>&1 || query_rc=$?
            case "$query_rc" in
                0) firewall-cmd --remove-port="$port/$proto" "${scope_args[@]}" >/dev/null 2>&1 || return 1 ;;
                1) ;;
                *) return 1 ;;
            esac
            query_rc=0
            firewall-cmd --query-port="$port/$proto" "${scope_args[@]}" >/dev/null 2>&1 || query_rc=$?
            [ "$query_rc" = 1 ] || return 1
        done
    elif command -v iptables >/dev/null 2>&1; then
        local tool query_rc
        for tool in iptables ip6tables; do
            command -v "$tool" >/dev/null 2>&1 || continue
            while :; do
                query_rc=0
                iptables_rule_state "$tool" "$port" "$proto" || query_rc=$?
                case "$query_rc" in
                    0) "$tool" -D INPUT -p "$proto" --dport "$port" -m comment --comment onebox -j ACCEPT >/dev/null 2>&1 || return 1 ;;
                    1) break ;;
                    *) printf '[错误] 无法确认 %s 规则已清理；保留端口记录。\n' "$tool" >&2; return 1 ;;
                esac
            done
        done
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || return 1

        fi
    else
        echo '无法确认防火墙规则已删除，保留追踪记录。' >&2
        return 1
    fi
    return 0
}

remove_all_fw_rules() {
    local port proto failed=0
    local UNINSTALLING=1
    [ -f "$FW_PORTS_FILE" ] || return 0
    while IFS="/" read -r port proto; do
        [ -n "$port" ] && [ -n "$proto" ] || continue
        if ! close_fw_port "$port" "$proto"; then failed=1; fi
    done < "$FW_PORTS_FILE"
    if [ "$failed" != 0 ]; then
        echo '部分防火墙规则未清理，记录已保留；请处理后重试。' >&2
        return 1
    fi
    rm -f "$FW_PORTS_FILE"
}

migrate_certs() {
    load_secrets || return 1
    [ -f "$CERT_DIR/fullchain.cer" ] || return 0
    (
        umask 077
        local kind=self d changed=0 complete=0 f
        [ "${CERT_TYPE:-}" != real ] || kind=real
        [ -f "$CERT_DIR/private.key" ] || { printf '%s\n' '旧证书私钥缺失，取消迁移。' >&2; exit 1; }
        for f in "$CERT_DIR/$kind.cer" "$CERT_DIR/$kind.key"; do
            [ ! -e "$f" ] && [ ! -L "$f" ] || { printf '%s\n' '证书迁移目标已存在，保留全部原文件。' >&2; exit 1; }
        done
        d=$(mktemp -d "$CONFIG_DIR/.cert-migrate.XXXXXX") || exit 1
        migration_finish() {
            local rc=$? failed=0 tmp
            trap - EXIT INT TERM
            if [ "$changed" = 1 ] && [ "$complete" = 0 ]; then
                tmp=$(mktemp "${CONFIG_FILE}.restore.XXXXXX") || failed=1
                if [ "$failed" = 0 ]; then
                    if ! cp -p "$d/config" "$tmp" || ! mv -f "$tmp" "$CONFIG_FILE"; then rm -f "$tmp"; failed=1; fi
                fi
                if [ -f "$d/secrets.absent" ]; then
                    rm -f "$SECRETS_FILE" || failed=1
                elif [ -f "$d/secrets" ]; then
                    tmp=$(mktemp "${SECRETS_FILE}.restore.XXXXXX") || failed=1
                    if [ "$failed" = 0 ]; then
                        if ! cp -p "$d/secrets" "$tmp" || ! mv -f "$tmp" "$SECRETS_FILE"; then rm -f "$tmp"; failed=1; fi
                    fi
                fi
                cp -p "$d/cert" "$CERT_DIR/fullchain.cer" || failed=1
                cp -p "$d/key" "$CERT_DIR/private.key" || failed=1
                if [ "$failed" = 0 ]; then
                    rm -f "$CERT_DIR/$kind.cer" "$CERT_DIR/$kind.key" || failed=1
                fi
            fi
            if [ "$failed" != 0 ]; then printf '证书迁移恢复失败，备份保留: %s\n' "$d" >&2; exit 1; fi
            rm -rf "$d"
            exit "$rc"
        }
        trap migration_finish EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        cp -p "$CONFIG_FILE" "$d/config" || exit 1
        if [ -e "$SECRETS_FILE" ]; then
            cp -p "$SECRETS_FILE" "$d/secrets" || exit 1
        else
            touch "$d/secrets.absent" || exit 1
        fi
        cp -p "$CERT_DIR/fullchain.cer" "$d/cert" &&
        cp -p "$CERT_DIR/private.key" "$d/key" || exit 1
        changed=1
        cp -p "$d/cert" "$CERT_DIR/$kind.cer" &&
        cp -p "$d/key" "$CERT_DIR/$kind.key" || exit 1
        apply_jq_config '
          (.inbounds[] | select(.tls.certificate_path? == $oldcert) | .tls.certificate_path) = $newcert |
          (.inbounds[] | select(.tls.key_path? == $oldkey) | .tls.key_path) = $newkey' \
          --arg oldcert "$CERT_DIR/fullchain.cer" --arg oldkey "$CERT_DIR/private.key" \
          --arg newcert "$CERT_DIR/$kind.cer" --arg newkey "$CERT_DIR/$kind.key" || exit 1
        check_kernel_config "$CONFIG_FILE" || exit 1
        if [ "$kind" = real ]; then save_secret REAL_DOMAIN "${DOMAIN:-}" || exit 1
        else save_secret SELF_DOMAIN "${DOMAIN:-}" || exit 1; fi
        remove_secret CERT_TYPE && remove_secret DOMAIN || exit 1
        rm -f "$CERT_DIR/fullchain.cer" "$CERT_DIR/private.key" || exit 1
        complete=1
    )
}

kernel_ok() {
    [ -x /usr/local/lib/onebox/sing-box ] || return 1
    local ver
    ver=$( ( /usr/local/lib/onebox/sing-box version ) 2>/dev/null ) || return 1
    echo "$ver" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+' || return 1
    return 0
}

require_kernel_binary() {
    local bin="${1:-/usr/local/lib/onebox/sing-box}"
    if [ ! -f "$bin" ]; then
        printf '[错误] sing-box 内核文件不存在：%s。请重新安装或执行 onebox update。\n' "$bin" >&2
        return 1
    fi
    if [ ! -x "$bin" ]; then
        printf '[错误] sing-box 内核文件不可执行：%s。请检查权限或重新安装。\n' "$bin" >&2
        return 1
    fi
}

check_kernel_config() {
    local config="$1" bin="${2:-/usr/local/lib/onebox/sing-box}"
    require_kernel_binary "$bin" || return 1
    "$bin" check -c "$config"
}

install_kernel_binary() {
    local source="$1" target=/usr/local/lib/onebox/sing-box
    mv -f "$source" "$target" || return 1
    require_kernel_binary "$target" || return 1
    # Validate the installed path before the transaction can report success.
    "$target" version
}

fetch_url() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --retry-max-time 600 --connect-timeout 15 \
            --max-time 300 -o "$out" "$url" && return 0
    fi
    : > "$out" || return 1
    if command -v wget >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 300 wget -T 30 -qO "$out" "$url" && return 0
        else
            wget -T 30 -qO "$out" "$url" && return 0
        fi
    fi
    return 1
}

stop_sing_box_if_present() {
    local state rc
    if [ "$SERVICE_MANAGER" = openrc ]; then
        if [ ! -e /etc/init.d/onebox ] && [ ! -L /etc/init.d/onebox ]; then return 0; fi
        rc-service onebox status >/dev/null 2>&1
        rc=$?
        [ "$rc" = 3 ] && return 0
        if [ "$rc" != 0 ]; then
            printf '无法确认 sing-box 状态，退出码：%s\n' "$rc" >&2
            return 1
        fi
        rc-service onebox stop || return 1
        rc-service onebox status >/dev/null 2>&1
        rc=$?
        [ "$rc" = 3 ] || { printf 'sing-box 未确认停止。\n' >&2; return 1; }
    else
        state=$(systemctl show onebox -p LoadState --value) || return 1
        case "$state" in
            not-found) return 0 ;;
            loaded|masked) ;;
            *) printf '无法确认 sing-box 服务：%s\n' "$state" >&2; return 1 ;;
        esac
        systemctl stop onebox || return 1
        state=$(systemctl show onebox -p ActiveState --value) || return 1
        case "$state" in inactive|failed) ;; *) printf 'sing-box 未停止：%s\n' "$state" >&2; return 1 ;; esac
    fi
    return 0
}

download_kernel_archive() {
    local ver="$1" d="$2" suffix="" loader digest actual name
    for loader in /lib/ld-musl-*.so.1; do [ ! -e "$loader" ] || suffix=-musl; done
    KERNEL_ASSET_STEM="sing-box-${ver}-linux-${SB_ARCH}${suffix}"
    if ! fetch_url "https://github.com/SagerNet/sing-box/releases/download/v${ver}/${KERNEL_ASSET_STEM}.tar.gz" "$d/archive"; then
        [ -n "$suffix" ] || return 1
        printf '[提示] 此版本/架构未取得 musl 包，尝试通用包。\n' >&2
        KERNEL_ASSET_STEM="sing-box-${ver}-linux-${SB_ARCH}"
        fetch_url "https://github.com/SagerNet/sing-box/releases/download/v${ver}/${KERNEL_ASSET_STEM}.tar.gz" "$d/archive" || return 1
    fi
    name="${KERNEL_ASSET_STEM}.tar.gz"
    if http_get "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${ver}" > "$d/release.json"; then
        digest=$(jq -r --arg name "$name" '.assets[]? | select(.name == $name) | .digest // empty' "$d/release.json") || return 1
        if [[ "$digest" =~ ^sha256:([0-9a-f]{64})$ ]]; then
            digest="${BASH_REMATCH[1]}"
            actual=$(sha256sum "$d/archive") || return 1
            [ "${actual%% *}" = "$digest" ] || { echo '[错误] 下载包 SHA-256 校验失败。' >&2; return 1; }
        else
            echo '[提示] 此发行包未提供 GitHub SHA-256 摘要，已通过 HTTPS 下载。' >&2
        fi
    else
        echo '[提示] 无法读取发行摘要（网络/API 限额）；已通过 HTTPS 下载。' >&2
    fi
}

install_kernel() {
    local ver="$1" mode="${2:-restart}"
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || return 1
    (
        umask 077
        local d newbin active=0 touched=0 done_ok=0 new_is_112=0 kernel_tx_owner="$BASHPID"
        mkdir -p /usr/local/lib/onebox || exit 1
        d=$(mktemp -d /usr/local/lib/onebox/.kernel-tx.XXXXXX) || exit 1
        kernel_tx_finish() {
            local rc=$? failed=0
            # An inherited EXIT trap must never roll back another shell's transaction.
            [ "$BASHPID" = "$kernel_tx_owner" ] || return 0
            trap - EXIT INT TERM
            if [ "$touched" = 1 ] && [ "$done_ok" = 0 ]; then
                stop_sing_box_if_present || failed=1
                if [ -f "$d/old_config" ]; then
                    if ! cp -p "$d/old_config" "$d/restore_cfg" || ! mv -f "$d/restore_cfg" "$CONFIG_FILE"; then failed=1; fi
                fi
                if [ -f "$d/old" ]; then
                    if ! cp -p "$d/old" "$d/restore" || ! mv -f "$d/restore" /usr/local/lib/onebox/sing-box; then failed=1; fi
                else
                    rm -f /usr/local/lib/onebox/sing-box || failed=1
                fi
                if [ "$failed" = 0 ] && [ "$active" = 1 ]; then
                    if [ "$SERVICE_MANAGER" = openrc ]; then
                        rc-service onebox start || failed=1
                        rc-service onebox status >/dev/null 2>&1 || failed=1
                    else
                        systemctl start onebox || failed=1
                        systemctl is-active --quiet onebox || failed=1
                    fi
                fi
            fi
            if [ "$failed" = 1 ]; then
                printf '内核或服务恢复失败，完整备份保留: %s\n' "$d" >&2
                exit 1
            fi
            rm -rf "$d"
            exit "$rc"
        }
        trap kernel_tx_finish EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        if [ "$SERVICE_MANAGER" = openrc ]; then
            rc-service onebox status >/dev/null 2>&1 && active=1
        else
            systemctl is-active --quiet onebox && active=1
        fi
        if [ -e /usr/local/lib/onebox/sing-box ]; then cp -p /usr/local/lib/onebox/sing-box "$d/old" || exit 1; fi
        if [ -f "$CONFIG_FILE" ]; then cp -p "$CONFIG_FILE" "$d/old_config" || exit 1; fi
        run_step "[1/4] 下载 sing-box v${ver} (${SB_ARCH})" download_kernel_archive "$ver" "$d" || exit 1
        mkdir "$d/extract" || exit 1
        run_step "[2/4] 解压内核" tar -xzf "$d/archive" -C "$d/extract" "$KERNEL_ASSET_STEM/sing-box" || exit 1
        newbin="$d/extract/$KERNEL_ASSET_STEM/sing-box"
        [ -f "$newbin" ] && [ ! -L "$newbin" ] && chown 0:0 "$newbin" && chmod 755 "$newbin" || exit 1
        if ! run_step "[3/4] 验证内核运行" "$newbin" version; then
            if [ "$PACKAGE_MANAGER" = apk ] && [[ "$KERNEL_ASSET_STEM" != *-musl ]]; then
                install_packages gcompat || exit 1
                run_step '验证兼容层及内核' "$newbin" version || exit 1
            else exit 1; fi
        fi
        sb_bin_ge_112 "$newbin" && new_is_112=1
        if [ -f "$CONFIG_FILE" ]; then
            cp -p "$CONFIG_FILE" "$d/test_config.json" || exit 1
            upgrade_config_schema "$d/test_config.json" "$new_is_112" || exit 1
            run_step "检查现有配置兼容性" check_kernel_config "$d/test_config.json" "$newbin" || exit 1
        fi
        touched=1
        if [ "$active" = 1 ]; then
            if [ "$SERVICE_MANAGER" = openrc ]; then run_step "停止旧内核" rc-service onebox stop || exit 1; else run_step "停止旧内核" systemctl stop onebox || exit 1; fi
        fi
        run_step "[4/4] 安装内核" install_kernel_binary "$newbin" || exit 1
        if [ -f "$d/test_config.json" ]; then
            mv -f "$d/test_config.json" "$CONFIG_FILE" || exit 1
        fi
        if [ "$mode" != norestart ]; then run_step "启动并检查服务" restart_service || exit 1; fi
        done_ok=1
        printf '==> 内核 v%s 安装完毕！\n' "$ver"
    )
}

install_packages() {
    case "$PACKAGE_MANAGER" in
        apk) run_step '安装依赖（apk）' apk add --no-cache "$@" ;;
        apt-get)
            if [ "${APT_INDEX_READY:-0}" != 1 ]; then
                run_step '更新软件包索引' apt-get update || return 1
                APT_INDEX_READY=1
            fi
            run_step '安装依赖（apt）' env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y --no-install-recommends "$@" ;;
        dnf|yum) run_step "安装依赖（$PACKAGE_MANAGER）" "$PACKAGE_MANAGER" install -y "$@" ;;
        zypper) run_step '安装依赖（zypper）' zypper --non-interactive install "$@" ;;
        pacman) run_step '安装依赖（pacman）' pacman -Syu --noconfirm --needed "$@" ;;
        *) printf '[错误] 不支持的包管理器。\n' >&2; return 3 ;;
    esac
}

ensure_deps() {
    local c pkg
    local -a pkgs=() missing=()
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 && continue
        missing+=("$c")
        pkg="$c"
        case "$c" in
            ss) case "$PACKAGE_MANAGER" in dnf|yum|zypper) pkg=iproute2; [ "$PACKAGE_MANAGER" = zypper ] || pkg=iproute ;; *) pkg=iproute2 ;; esac ;;
            crontab) case "$PACKAGE_MANAGER" in apk) pkg=dcron ;; apt-get) pkg=cron ;; *) pkg=cronie ;; esac ;;
            flock) [ "$PACKAGE_MANAGER" = apk ] && pkg=flock || pkg=util-linux ;;
            setsid) [ "$PACKAGE_MANAGER" = apk ] && pkg=util-linux-misc || pkg=util-linux ;;
            mkfifo) pkg=coreutils ;;
            sha256sum|base64|timeout|date|mv) pkg=coreutils ;;
            sysctl|ps) case "$PACKAGE_MANAGER" in apk|pacman) pkg=procps-ng ;; apt-get) pkg=procps ;; *) pkg=procps-ng ;; esac ;;
            modprobe) pkg=kmod ;;
            awk) pkg=gawk ;;
            grep) pkg="grep" ;;
            sed) pkg="sed" ;;
            find) pkg=findutils ;;
        esac
        pkgs+=("$pkg")
    done
    # A present curl binary does not imply that the CA trust store is installed.
    if [ ! -s /etc/ssl/certs/ca-certificates.crt ] && [ ! -s /etc/pki/tls/certs/ca-bundle.crt ] &&
       [ ! -s /var/lib/ca-certificates/ca-bundle.pem ]; then pkgs+=(ca-certificates); fi
    [ "${#pkgs[@]}" -gt 0 ] || return 0
    printf '[信息] 自动安装依赖：%s\n' "${pkgs[*]}" >&2
    install_packages "${pkgs[@]}" || { printf '[错误] 依赖安装失败，请检查网络、软件源及包管理器锁；RPM 系统可能需要启用 EPEL。\n' >&2; return 1; }
    for c in "${missing[@]}"; do
        command -v "$c" >/dev/null 2>&1 || { printf '[错误] 安装后仍缺少命令：%s\n' "$c" >&2; return 1; }
    done
    if [ ! -s /etc/ssl/certs/ca-certificates.crt ] && [ ! -s /etc/pki/tls/certs/ca-bundle.crt ] &&
       [ ! -s /var/lib/ca-certificates/ca-bundle.pem ]; then
        printf '[错误] 系统 CA 证书安装未生效。\n' >&2; return 1
    fi
}

ensure_cron() {
    ensure_deps crontab || return 1
    local svc=crond candidate state pkg
    if [ "$SERVICE_MANAGER" = openrc ]; then
        if [ ! -e /etc/init.d/crond ] && [ ! -e /etc/init.d/dcron ]; then
            case "$PACKAGE_MANAGER" in apk) pkg=dcron ;; apt-get) pkg=cron ;; *) pkg=cronie ;; esac
            install_packages "$pkg" || return 1
        fi
        [ -e /etc/init.d/dcron ] && svc=dcron
        rc-update add "$svc" default && rc-service "$svc" start && rc-service "$svc" status
    else
        for candidate in cron crond cronie; do
            state=$(systemctl show "$candidate" -p LoadState --value) || return 1
            if [ "$state" = loaded ] || [ "$state" = masked ]; then svc="$candidate"; break; fi
        done
        if [ "$state" = not-found ]; then
            case "$PACKAGE_MANAGER" in apt-get) pkg=cron; svc=cron ;; zypper) pkg=cronie; svc=cron ;; pacman) pkg=cronie; svc=cronie ;; *) pkg=cronie; svc=crond ;; esac
            install_packages "$pkg" || return 1
        fi
        systemctl enable --now "$svc" && systemctl is-active --quiet "$svc"
    fi
}

init_base() {
    ensure_deps curl wget jq tar gzip openssl ss sha256sum base64 flock || return 1

    if ! kernel_ok; then
        echo -e "${CYAN}[信息] ==> 正在获取最新版 sing-box 内核信息...${PLAIN}"
        local VERSION
        VERSION="${CLI_VERSION:-latest}"
        [ "$VERSION" != latest ] || VERSION=$(get_latest_version)

        if [ -z "$VERSION" ]; then
            echo -e "${YELLOW}[提示] 获取版本信息失败！${PLAIN}"
            if [ "$NON_INTERACTIVE" = 1 ]; then
                printf '[错误] 无法取得最新版本；请检查网络或指定 --version。\n' >&2
                return 1
            fi
            ask "请手动输入要安装的 sing-box 版本号 (例如 1.10.1): " VERSION
            if [ -z "$VERSION" ]; then
                echo -e "${RED}[错误] 未输入版本号，安装终止。${PLAIN}"
                return 1
            fi
        fi
        install_kernel "$VERSION" norestart || return 1
        KERNEL_REINSTALLED=1
    fi

    mkdir -p "$CONFIG_DIR" "$CERT_DIR" || return 1
    chmod 700 "$CONFIG_DIR" "$CERT_DIR" || return 1

    if [ -f "$CONFIG_FILE" ]; then
        if ! jq -e '.inbounds | type == "array"' "$CONFIG_FILE" >/dev/null 2>&1; then
            echo -e "${RED}[错误] 检测到 $CONFIG_FILE 已损坏（非法 JSON 或缺少 inbounds 数组）！${PLAIN}"
            ask "是否重建为空白配置？原文件会被备份，但现有节点将丢失。(y/n) [默认: n]: " rebuild
            if [[ "${rebuild:-n}" != "y" && "${rebuild:-n}" != "Y" ]]; then
                echo -e "${YELLOW}[提示] 已取消，未做任何修改。请手动修复该文件后再运行本脚本。${PLAIN}"
                return 1
            fi
            local broken_bak
            broken_bak="${CONFIG_FILE}.broken.$(date +%Y%m%d%H%M%S)"
            if mv "$CONFIG_FILE" "$broken_bak" 2>/dev/null; then
                echo -e "${YELLOW}[提示] 原文件已备份为: ${broken_bak}${PLAIN}"
            else
                return 1
            fi
        fi
    fi

    local is_112=0
    sb_ge_112 && is_112=1

    if [ ! -f "$CONFIG_FILE" ]; then
        if [ "$is_112" -eq 1 ]; then
            echo '{"log":{"level":"info","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[{"ip_is_private":true,"action":"reject"}]}}' > "$CONFIG_FILE"
        else
            echo '{"log":{"level":"info","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}],"route":{"rules":[{"ip_is_private":true,"outbound":"block"}]}}' > "$CONFIG_FILE"
        fi
        chmod 600 "$CONFIG_FILE" || return 1
    else
        upgrade_config_schema "$CONFIG_FILE" "$is_112" || return 1
    fi
    check_kernel_config "$CONFIG_FILE" || return 1
    migrate_certs || return 1

    if [ "${KERNEL_REINSTALLED:-0}" -eq 1 ]; then
        local n
        n=$(jq '.inbounds | length' "$CONFIG_FILE" 2>/dev/null)
        if [ -n "$n" ] && [ "$n" -gt 0 ]; then
            echo -e "${CYAN}[信息] ==> 检测到已有节点，正在用新内核重启服务...${PLAIN}"
            if restart_service; then
                echo -e "${GREEN}[完成] ==> 服务已恢复运行。${PLAIN}"
            else
                echo -e "${RED}[错误] ==> 服务启动失败！请用 [6) 运行管理] 查看，或执行:${PLAIN}"
                echo -e "${YELLOW}[提示]     sing-box check -c ${CONFIG_FILE}${PLAIN}"
                return 1
            fi
        fi
    fi
}

restart_service() {
    local INBOUND_COUNT service_tmp
    if ! INBOUND_COUNT=$(jq -r 'if (.inbounds | type) == "array" then (.inbounds | length) else error("invalid inbounds") end' "$CONFIG_FILE" 2>/dev/null); then
        printf '%s\n' '配置无法读取或已损坏，拒绝操作服务。' >&2
        return 1
    fi
    if [ "$INBOUND_COUNT" -eq 0 ]; then
        stop_sing_box_if_present || return 1
        printf '[提示] 暂无节点，无需启动服务。\n'
        return 0
    fi

    if ! check_kernel_config "$CONFIG_FILE"; then return 1; fi

    if [ "$SERVICE_MANAGER" == openrc ]; then
        if [ ! -e "/etc/init.d/onebox" ] && [ ! -L "/etc/init.d/onebox" ]; then
            service_tmp=$(mktemp "/etc/init.d/onebox.tmp.XXXXXX") || return 1
            SB_OWNED_TEMP_FILES+=("$service_tmp")
            if ! cat > "$service_tmp" << 'EOF'
#!/sbin/openrc-run
name="onebox"
command="/usr/local/lib/onebox/sing-box"
command_args="run -c /etc/onebox/config.json"
command_background=true
pidfile="/var/run/onebox.pid"
rc_ulimit="-n 65535"
depend() { need net; }
EOF
            then rm -f "$service_tmp"; return 1; fi
            if ! chmod 755 "$service_tmp" || ! mv -f "$service_tmp" "/etc/init.d/onebox"; then
                rm -f "$service_tmp"
                return 1
            fi
        fi
        rc-update add onebox default || return 1
        rc-service onebox restart || return 1
        sleep 2
        if ! rc-service onebox status >/dev/null 2>&1; then return 1; fi
    else
        if [ ! -e "/etc/systemd/system/onebox.service" ] && [ ! -L "/etc/systemd/system/onebox.service" ]; then
            service_tmp=$(mktemp "/etc/systemd/system/onebox.service.tmp.XXXXXX") || return 1
            SB_OWNED_TEMP_FILES+=("$service_tmp")
            if ! cat > "$service_tmp" << 'EOF'
[Unit]
Description=sing-box service
Wants=network-online.target
After=network.target network-online.target
[Service]
ExecStart=/usr/local/lib/onebox/sing-box run -c /etc/onebox/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
            then rm -f "$service_tmp"; return 1; fi
            if ! chmod 644 "$service_tmp" || ! mv -f "$service_tmp" "/etc/systemd/system/onebox.service"; then
                rm -f "$service_tmp"
                return 1
            fi
        fi
        systemctl daemon-reload || return 1
        local enable_output enable_rc
        if enable_output=$(systemctl enable onebox 2>&1); then
            :
        else
            enable_rc=$?
            printf '[错误] 设置 sing-box 开机自启失败（退出码 %s）。\n%s\n' "$enable_rc" "$enable_output" >&2
            return "$enable_rc"
        fi
        systemctl restart onebox || return 1
        sleep 2
        if [ "$(systemctl is-active onebox 2>/dev/null)" != "active" ]; then
            sleep 2
            [ "$(systemctl is-active onebox 2>/dev/null)" != "active" ] && return 1
        fi
    fi
    return 0
}

get_domain() {
    local prompt="$1"
    local default="$2"
    local allow_colon="${3:-false}"

    local val
    if [ "$NON_INTERACTIVE" = 1 ]; then
        case "$prompt" in
            *Argo*IP*) val="${CLI_EDGE:-$default}" ;;
            *Argo*域名*) val="$CLI_DOMAIN" ;;
            *解析到本机*) val="$CLI_DOMAIN" ;;
            *) val="${CLI_SNI:-$default}" ;;
        esac
        [ -n "$val" ] || die "缺少域名参数：$prompt" 2
        valid_host "$val" "$allow_colon" || die "域名/IP 格式错误：$val" 2
        printf '%s\n' "$val"
        return 0
    fi
    while true; do
        if [ -n "$default" ]; then
            ask "$prompt [默认: $default]: " val
            val=${val:-$default}
        else
            ask "$prompt: " val
        fi
        if valid_host "$val" "$allow_colon"; then
            break
        else
            if [ "$allow_colon" == "true" ]; then
                echo -e "${RED}[错误] 错误：格式不正确！必须包含字母或数字，且不得包含空格或特殊符号。${PLAIN}" >&2
            else
                echo -e "${RED}[错误] 错误：格式不正确！纯域名不支持冒号，且必须包含字母或数字。${PLAIN}" >&2
            fi
        fi
    done
    printf '%s\n' "$val"
}

reality_sni_catalog() {
    # Candidate metadata adapted from chnnic/Reality-SNI-Check (MIT):
    # https://github.com/chnnic/Reality-SNI-Check
    # Upstream snapshot df1369dc080470d2; all 98 candidates except 4 Apple hosts.
    # Columns: category, affiliation region (not IP geolocation), hostname.
    # Korea additionally tags Samsung and LG; all other tags follow upstream.
    cat <<'EOF'
cdn global www.cloudflare.com
cdn global www.amazon.com
cdn global addons.mozilla.org
cdn global www.python.org
cdn global www.fastly.com
cloud global aws.amazon.com
cloud global azure.microsoft.com
cloud global www.digitalocean.com
cloud global gitlab.com
cloud global registry.npmjs.org
cloud global www.jsdelivr.com
cloud global www.vercel.com
cloud global www.netlify.com
cloud global www.oracle.com
cloud global www.ibm.com
tech global www.amd.com
tech global www.intel.com
tech global www.nvidia.com
tech global www.qualcomm.com
tech global www.arm.com
tech global www.tesla.com
tech kr www.samsung.com
tech global www.sony.com
tech kr www.lg.com
tech global www.dell.com
tech global www.hp.com
tech global www.lenovo.com
tech global www.cisco.com
tech global www.adobe.com
fin global www.paypal.com
fin global www.visa.com
fin global www.mastercard.com
fin global www.americanexpress.com
fin global www.stripe.com
fin global www.jpmorgan.com
fin global www.goldmansachs.com
fin global www.hsbc.com
fin global www.citi.com
fin global www.blackrock.com
edu us www.mit.edu
edu us www.stanford.edu
edu us www.harvard.edu
edu us www.berkeley.edu
edu us www.cornell.edu
edu us www.princeton.edu
edu us www.yale.edu
edu us www.columbia.edu
edu eu www.ox.ac.uk
edu eu www.cam.ac.uk
edu eu www.imperial.ac.uk
edu eu www.ethz.ch
edu eu www.epfl.ch
edu jp www.u-tokyo.ac.jp
edu jp www.kyoto-u.ac.jp
edu sg www.nus.edu.sg
edu sg www.ntu.edu.sg
edu hk www.hku.hk
edu hk www.hkust.edu.hk
edu cn www.tsinghua.edu.cn
edu cn www.pku.edu.cn
edu au www.unimelb.edu.au
edu us www.utoronto.ca
media global www.imdb.com
social global www.wordpress.com
social global www.snapchat.com
gaming global www.epicgames.com
gaming global www.riotgames.com
gaming global www.ea.com
gaming global www.ubisoft.com
gaming global www.playstation.com
gaming global www.nintendo.com
gaming global www.xbox.com
gaming global www.blizzard.com
ecom global www.ebay.com
ecom global www.walmart.com
ecom global www.target.com
ecom global www.bestbuy.com
ecom global www.shopify.com
ecom cn www.alibaba.com
ecom eu www.ikea.com
ecom global www.nike.com
ecom eu www.adidas.com
ecom eu www.zara.com
region jp www.lovelive-anime.jp
region jp www.yahoo.co.jp
region jp www.ana.co.jp
region eu www.mercedes-benz.com
region eu www.bmw.com
region eu www.audi.com
region eu www.lufthansa.com
region sg www.singaporeair.com
region hk www.cathaypacific.com
region au www.qantas.com
region global www.salesforce.com
EOF
}

reality_sni_categories() {
    cat <<'EOF'
cdn 全球CDN/anycast
cloud 云/开发基础设施
tech 科技/半导体大厂
fin 金融/支付/银行
edu 大学/教育机构
media 流媒体/内容
social 社交平台
gaming 游戏平台
ecom 电商/零售/品牌
region 区域锚点
EOF
}

reality_sni_regions() {
    cat <<'EOF'
global 全球通用/CDN
us 美国/北美
eu 欧洲
jp 日本
hk 香港
sg 东南亚/新加坡
cn 中国大陆
au 澳洲
kr 韩国
EOF
}

valid_reality_sni_region() {
    case "$1" in all|global|us|eu|jp|hk|sg|cn|au|kr) return 0 ;; *) return 1 ;; esac
}

valid_reality_sni_categories() {
    local key input="${1//,/ }"
    local -a keys=()
    input="${input//$'\n'/ }"
    read -r -a keys <<< "$input"
    [ "${#keys[@]}" -gt 0 ] || return 1
    for key in "${keys[@]}"; do
        case "$key" in all|cdn|cloud|tech|fin|edu|media|social|gaming|ecom|region) ;; *) return 1 ;; esac
    done
}

reality_sni_allowed_host() {
    valid_host "$1" || return 1
    case "${1,,}" in
        apple.com|*.apple.com|icloud.com|*.icloud.com|mzstatic.com|*.mzstatic.com) return 1 ;;
    esac
}

normalize_reality_sni_hosts() {
    local input="${1//,/ }" host
    local -a entries=()
    local -A normalized_sni_seen=()
    input="${input//$'\n'/ }"
    read -r -a entries <<< "$input"
    [ "${#entries[@]}" -gt 0 ] && [ "${#entries[@]}" -le 256 ] || {
        printf '[错误] 自定义列表需要 1–256 个域名。\n' >&2; return 1;
    }
    for host in "${entries[@]}"; do
        host="${host,,}"
        host="${host#https://}"; host="${host#http://}"
        host="${host%%[/?#]*}"; host="${host%:443}"; host="${host%.}"
        reality_sni_allowed_host "$host" || {
            printf '[错误] SNI 格式无效或属于已排除的 Apple 域名：%s\n' "$host" >&2; return 1;
        }
        if [ -z "${normalized_sni_seen[$host]:-}" ]; then printf '%s\n' "$host"; normalized_sni_seen[$host]=1; fi
    done
}

reality_sni_candidates() {
    local area="${1:-all}" categories="${2:-all}" custom="${3:-}"
    valid_reality_sni_region "$area" && valid_reality_sni_categories "$categories" || return 1
    if [ -n "$custom" ]; then normalize_reality_sni_hosts "$custom"; return $?; fi
    reality_sni_catalog | awk -v area="$area" -v cats="${categories//,/ }" '
      BEGIN {n=split(cats, keys, /[[:space:]]+/); for(i=1;i<=n;i++) selected[keys[i]]=1}
      (area=="all" || $2=="global" || $2==area) && (selected["all"] || selected[$1]) && !seen[$3]++ {print $3}'
}

manual_reality_sni() {
    local manual_host
    if [ "$NON_INTERACTIVE" = 1 ]; then
        reality_sni_allowed_host "${CLI_SNI:-}" || return 1
        printf '%s\n' "$CLI_SNI"; return 0
    fi
    while true; do
        # Read in the selector itself so TERM can interrupt an idle prompt.
        ask '请输入伪装域名 [默认: www.cloudflare.com]: ' manual_host
        manual_host="${manual_host:-www.cloudflare.com}"
        if reality_sni_allowed_host "$manual_host"; then printf '%s\n' "$manual_host"; return 0; fi
        printf '[错误] 域名格式无效或属于已排除的 Apple 域名，请重新输入。\n' >&2
    done
}

prompt_sni_integer() {
    local prompt="$1" default="$2" maximum="$3" destination="$4" number
    while true; do
        ask "$prompt [默认: $default]: " number
        number="${number:-$default}"
        if [[ "$number" =~ ^[1-9][0-9]?$ ]] && [ "$number" -le "$maximum" ]; then
            printf -v "$destination" '%s' "$number"; return 0
        fi
        printf '[提示] 请输入 1–%s 的整数。\n' "$maximum" >&2
    done
}

configure_reality_sni_scan() {
    # These sni_* variables belong to run_reality_sni_selection (Bash dynamic scope).
    local mode selection key label count item categories candidate_text
    local -a keys=() entries=()
    while true; do
        printf '\nSNI 检测范围：\n 1) 快速检测（CDN、云、科技）\n 2) 全部候选（默认）\n 3) 按分类检测（可多选）\n 4) 按地区推荐\n 5) 自定义域名/网址列表\n 6) 检测设置（次数=%s，超时=%ss，并发=%s）\n 0) 手动填写 SNI\n' "$sni_samples" "$sni_timeout" "$sni_jobs" >&2
        ask '请选择 [0-6，默认: 2]: ' mode
        case "${mode:-2}" in
            0) return 2 ;;
            1) sni_region=all; sni_categories=cdn,cloud,tech; sni_hosts=""; return 0 ;;
            2) sni_region=all; sni_categories=all; sni_hosts=""; return 0 ;;
            3)
                keys=()
                while read -r key label; do
                    keys+=("$key")
                    candidate_text=$(reality_sni_candidates all "$key") || return 1
                    count=$(printf '%s\n' "$candidate_text" | awk 'NF {n++} END {print n+0}')
                    printf ' %s) %s [%s]（%s 站）\n' "${#keys[@]}" "$label" "$key" "$count" >&2
                done <<< "$(reality_sni_categories)"
                ask '输入分类编号或键，多个用空格/逗号分隔；a 全选，0 返回: ' selection
                [ "$selection" != 0 ] || continue
                selection="${selection//,/ }"; categories=""; entries=()
                read -r -a entries <<< "$selection"
                for item in "${entries[@]}"; do
                    if [ "$item" = a ] || [ "$item" = all ]; then categories=all; break; fi
                    if [[ "$item" =~ ^[1-9][0-9]?$ ]] && [ "$item" -le "${#keys[@]}" ]; then item="${keys[item-1]}"; fi
                    categories+="${categories:+,}$item"
                done
                if valid_reality_sni_categories "$categories"; then
                    sni_region=all; sni_categories="$categories"; sni_hosts=""; return 0
                fi
                printf '[提示] 分类无效，请重新选择。\n' >&2 ;;
            4)
                keys=()
                printf '地区为静态归属标签；检测该区站点＋全球通用站，不进行 IP 地理定位。\n' >&2
                while read -r key label; do
                    keys+=("$key")
                    candidate_text=$(reality_sni_candidates "$key") || return 1
                    count=$(printf '%s\n' "$candidate_text" | awk 'NF {n++} END {print n+0}')
                    printf ' %s) %s [%s]（%s 站）\n' "${#keys[@]}" "$label" "$key" "$count" >&2
                done <<< "$(reality_sni_regions)"
                ask '输入地区编号或键（0 返回）: ' selection
                [ "$selection" != 0 ] || continue
                if [[ "$selection" =~ ^[1-9]$ ]]; then selection="${keys[selection-1]}"; fi
                if valid_reality_sni_region "$selection"; then
                    sni_region="$selection"; sni_categories=all; sni_hosts=""; return 0
                fi
                printf '[提示] 地区无效，请重新选择。\n' >&2 ;;
            5)
                ask '输入域名/HTTPS 网址，多个用空格或逗号分隔（0 返回）: ' selection
                [ "$selection" != 0 ] || continue
                if candidate_text=$(normalize_reality_sni_hosts "$selection"); then
                    sni_region=all; sni_categories=all; sni_hosts="$candidate_text"; return 0
                fi ;;
            6)
                prompt_sni_integer '每站测速次数（1–5，取最小值）' "$sni_samples" 5 sni_samples || return 1
                prompt_sni_integer '单次请求超时秒数（1–15）' "$sni_timeout" 15 sni_timeout || return 1
                prompt_sni_integer '并发检测上限（1–16，按 PID 额度下调）' "$sni_jobs" 16 sni_jobs || return 1 ;;
            *) printf '[提示] 请输入有效编号。\n' >&2 ;;
        esac
    done
}

# Read task limits with Bash builtins: the measurement must not need a spare PID.
onebox_probe_pids_budget() {
    local proc_root="${1:-/proc}" id controllers path v2_path='' v1_path='' line left
    local mount_root mount_dir directory relative ceiling current free soft key a b rest status uid threads used=0
    sni_pid_headroom=-1
    sni_pid_source='未发现可见的进程限制'
    if [ -r "$proc_root/self/cgroup" ] && [ -r "$proc_root/self/mountinfo" ]; then
        while IFS=: read -r id controllers path; do
            if [ "$id" = 0 ] && [ -z "$controllers" ]; then v2_path="$path"; fi
            case ",$controllers," in *,pids,*) v1_path="$path" ;; esac
        done < "$proc_root/self/cgroup"
        while IFS= read -r line; do
            case "$line" in
                *' - cgroup2 '*) path="$v2_path" ;;
                *' - cgroup '*) case "${line#* - cgroup }" in *,pids|*,pids,*|*' pids '*) path="$v1_path" ;; *) continue ;; esac ;;
                *) continue ;;
            esac
            [ -n "$path" ] || continue
            left="${line%% - *}"
            read -r id a b mount_root mount_dir rest <<< "$left"
            # mountinfo escapes whitespace and backslashes in paths.
            printf -v mount_root '%b' "$mount_root"
            printf -v mount_dir '%b' "$mount_dir"
            case "$path" in
                "$mount_root") relative='' ;;
                "$mount_root"/*) relative="${path#"$mount_root"}" ;;
                *) relative="$path" ;;
            esac
            directory="${mount_dir%/}/${relative#/}"; directory="${directory%/}"
            while :; do
                if [ -r "$directory/pids.max" ] && [ -r "$directory/pids.current" ]; then
                    read -r ceiling < "$directory/pids.max"
                    read -r current < "$directory/pids.current"
                    if [[ "$ceiling" =~ ^[0-9]+$ && "$current" =~ ^[0-9]+$ ]]; then
                        free=$((ceiling-current)); [ "$free" -ge 0 ] || free=0
                        if [ "$sni_pid_headroom" -lt 0 ] || [ "$free" -lt "$sni_pid_headroom" ]; then
                            sni_pid_headroom="$free"; sni_pid_source="$directory ($current/$ceiling)"
                        fi
                    fi
                fi
                [ "$directory" != "$mount_dir" ] && [[ "$directory" == "$mount_dir"/* ]] || break
                directory="${directory%/*}"
            done
        done < "$proc_root/self/mountinfo"
    fi
    # RLIMIT_NPROC counts threads of the real UID; it does not apply to root.
    if [ "$UID" != 0 ] && [ -r "$proc_root/self/limits" ]; then
        soft=''
        while read -r key a b rest; do
            if [ "$key $a" = 'Max processes' ]; then soft="$b"; break; fi
        done < "$proc_root/self/limits"
        if [[ "$soft" =~ ^[0-9]+$ ]]; then
            for status in "$proc_root"/[0-9]*/status; do
                [ -r "$status" ] || continue
                uid=''; threads=1
                while read -r key a rest; do
                    case "$key" in Uid:) uid="$a" ;; Threads:) threads="$a"; break ;; esac
                done < "$status"
                if [ "$uid" = "$UID" ] && [[ "$threads" =~ ^[0-9]+$ ]]; then used=$((used+threads)); fi
            done
            free=$((soft-used)); [ "$free" -ge 0 ] || free=0
            if [ "$sni_pid_headroom" -lt 0 ] || [ "$free" -lt "$sni_pid_headroom" ]; then
                sni_pid_headroom="$free"; sni_pid_source="ulimit -u ($used/$soft，可见 UID 线程)"
            fi
        fi
    fi
}

onebox_safe_sni_jobs() {
    onebox_probe_pids_budget
    sni_effective_jobs="$1"
    # Each worker: Bash + curl + one resolver thread; normally reserve four tasks.
    if [ "$sni_pid_headroom" -ge 0 ]; then
        local available=$(((sni_pid_headroom-4)/3))
        [ "$available" -ge 0 ] || available=0
        [ "$available" -ge "$sni_effective_jobs" ] || sni_effective_jobs="$available"
        # Tight containers can still scan serially, leaving one task beyond the worker.
        # Candidate preparation can also need four tasks, so never fall back at three.
        if [ "$sni_effective_jobs" -lt 1 ] && [ "$sni_pid_headroom" -ge 4 ]; then
            sni_effective_jobs=1
        fi
    fi
    [ "$sni_effective_jobs" -gt 0 ]
}

check_reality_sni_curl() {
    local line version major minor tls_major tls_minor tls_patch features='' backend=''
    sni_curl_certinfo=0
    CURL_SSL_BACKEND=openssl curl -q --version > "$sni_work_dir/curl-version" || return 1
    while IFS= read -r line; do
        case "$line" in
            curl\ *) read -r backend version _ <<< "$line"; backend="$line" ;;
            Features:*) features="$line" ;;
        esac
    done < "$sni_work_dir/curl-version"
    IFS=. read -r major minor _ <<< "$version"
    if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] ||
       ! { [ "$major" -gt 7 ] || { [ "$major" = 7 ] && [ "$minor" -ge 73 ]; }; } ||
       [[ "$backend" != *' OpenSSL/'* || " $features " != *' HTTP2 '* ]]; then
        printf '[错误] 自动检测需要 curl ≥ 7.73、OpenSSL TLS 后端和 HTTP2 支持；请通过系统软件源升级 curl，或用 --sni 显式指定域名。\n' >&2
        return 1
    fi
    if [[ "$backend" =~ [[:space:]]OpenSSL/([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
        tls_major="${BASH_REMATCH[1]}"; tls_minor="${BASH_REMATCH[2]}"; tls_patch="${BASH_REMATCH[3]}"
        if [ "$tls_major" -lt 1 ] || { [ "$tls_major" = 1 ] && { [ "$tls_minor" -lt 1 ] || { [ "$tls_minor" = 1 ] && [ "$tls_patch" -lt 1 ]; }; }; }; then
            printf '[错误] 自动检测需要支持 TLS 1.3 的 OpenSSL ≥ 1.1.1；请升级系统 curl 或显式指定 --sni。\n' >&2
            return 1
        fi
    else
        printf '[错误] 无法确认 curl 的 OpenSSL 版本；请升级系统 curl 或显式指定 --sni。\n' >&2
        return 1
    fi
    if [ "$major" -gt 7 ] || [ "$minor" -ge 88 ]; then sni_curl_certinfo=1; fi
    if [ "$sni_curl_certinfo" = 0 ]; then
        printf '[提示] 当前 curl 不支持证书链计数，将标为链长度未知并列在已知链之后。\n' >&2
    fi
}

probe_reality_sni() {
    local host="$1" samples="${2:-3}" limit="${3:-5}" payload verify http elapsed chain
    local round whole fraction current best_chain=0 ms=2147483647 format
    reality_sni_allowed_host "$host" || return 1
    format='%{ssl_verify_result}\t%{http_version}\t%{time_appconnect}\t0'
    [ "${sni_curl_certinfo:-0}" != 1 ] || format='%{ssl_verify_result}\t%{http_version}\t%{time_appconnect}\t%{num_certs}'
    for ((round=0; round<samples; round++)); do
        # exec replaces the command-substitution shell; no openssl/timeout/pipeline workers.
        if ! payload=$(LC_ALL=C CURL_SSL_BACKEND=openssl exec curl -q --noproxy '*' -sS --connect-timeout "$limit" --max-time "$limit" \
            --http2 --tlsv1.3 --tls-max 1.3 --curves X25519 --head \
            --output /dev/null --write-out "$format" "https://$host/"); then
            [ "$round" -gt 0 ] || return 1
            continue
        fi
        IFS=$'\t' read -r verify http elapsed chain <<< "$payload"
        if [ "$verify" != 0 ] || [ "$http" != 2 ] || ! [[ "$elapsed" =~ ^[0-9]+\.[0-9]+$ && "$chain" =~ ^[0-9]+$ ]] ||
           { [ "${sni_curl_certinfo:-0}" = 1 ] && [ "$chain" = 0 ]; }; then
            [ "$round" -gt 0 ] || return 1
            continue
        fi
        whole="${elapsed%%.*}"; fraction="${elapsed#*.}0000"
        current=$((10#$whole*1000 + 10#${fraction:0:3} + (10#${fraction:3:1} >= 5)))
        [ "$current" -gt 0 ] || current=1
        [ "$current" -ge "$ms" ] || ms="$current"
        [ "$chain" -le "$best_chain" ] || best_chain="$chain"
    done
    [ "$ms" != 2147483647 ] || return 1
    printf '%s\t%s\n' "$ms" "$best_chain"
}

reality_sni_worker_exited() {
    local worker="$1" stat state
    kill -0 "$worker" 2>/dev/null || return 0
    if [ -r "/proc/$worker/stat" ]; then
        IFS= read -r stat < "/proc/$worker/stat" || return 1
        state="${stat##*) }"; state="${state%% *}"
        # During an EXIT trap Bash may defer reaping; wait is safe once the child is a zombie.
        if [ "$state" = Z ] || [ "$state" = X ]; then return 0; fi
    fi
    return 1
}

stop_reality_sni_worker() {
    local worker="$1" tick
    # Kill the session, including curl and its resolver, even if the worker shell is waiting.
    kill -TERM -- "-$worker" "$worker" 2>/dev/null || :
    for ((tick=0; tick<3; tick++)); do
        reality_sni_worker_exited "$worker" && break
        IFS= read -r -t 0.1 -u 9 _ || :
    done
    kill -KILL -- "-$worker" "$worker" 2>/dev/null || :
    for ((tick=0; tick<10; tick++)); do
        if reality_sni_worker_exited "$worker"; then wait "$worker" 2>/dev/null || :; return 0; fi
        IFS= read -r -t 0.1 -u 9 _ || :
    done
    printf '[错误] 检测任务 %s 在强制终止后仍未退出；停止扫描，请检查主机内核/容器状态。\n' "$worker" >&2
    return 1
}

cleanup_reality_sni_workers() {
    local worker
    for worker in "${sni_pids[@]}"; do
        [ -z "$worker" ] || stop_reality_sni_worker "$worker" || :
    done
    if [ "${sni_poll_open:-0}" = 1 ]; then exec 9>&-; sni_poll_open=0; fi
    [ -z "$sni_work_dir" ] || rm -rf -- "$sni_work_dir"
    return 0
}

run_reality_sni_selection() {
    # Own only scan resources; never inherit the caller's configuration rollback trap.
    trap - EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    local auto_sni answer host score chain ranked index=0 slot batch_start=0 position completed=0 tier result scan_rc probe_rc
    local sni_effective_jobs sni_pid_headroom sni_pid_source sni_curl_certinfo worker launched pending last_jobs=0 sni_launch_abort=0
    local -a deadlines=()
    local sni_region="${CLI_SNI_REGION:-all}" sni_categories="${CLI_SNI_CATEGORIES:-all}" sni_hosts="${CLI_SNI_HOSTS:-}"
    local sni_samples="${CLI_SNI_SAMPLES:-3}" sni_timeout="${CLI_SNI_TIMEOUT:-5}" sni_jobs="${CLI_SNI_JOBS:-8}"
    local -a candidates=() matches=() hosts=()
    # Persist in this isolated shell until its EXIT trap runs after function return.
    sni_work_dir=""; sni_pids=(); sni_poll_open=0
    trap cleanup_reality_sni_workers EXIT
    if [ "$NON_INTERACTIVE" = 1 ] && [ -n "${CLI_SNI:-}" ]; then manual_reality_sni; return $?; fi
    if [ "$NON_INTERACTIVE" = 0 ]; then
        while true; do
            ask '是否自动检测并推荐 SNI？(y/n) [默认: y]: ' auto_sni
            case "${auto_sni:-y}" in
                y|Y) break ;;
                n|N) manual_reality_sni; return $? ;;
                *) printf '[提示] 请输入 y 或 n。\n' >&2 ;;
            esac
        done
        configure_reality_sni_scan; scan_rc=$?
        if [ "$scan_rc" = 2 ]; then manual_reality_sni; return $?; fi
        [ "$scan_rc" = 0 ] || return "$scan_rc"
    fi
    # Check before dependency/candidate subprocesses, then recalculate for every batch.
    if ! onebox_safe_sni_jobs "$sni_jobs"; then
        printf '[错误] 剩余进程额度不足，无法安全启动 SNI 检测：%s。请释放资源或显式指定 --sni。\n' "$sni_pid_source" >&2
        if [ "$NON_INTERACTIVE" = 0 ]; then manual_reality_sni; return $?; fi
        return 1
    fi
    if ! ensure_deps curl setsid mkfifo; then
        if [ "$NON_INTERACTIVE" = 1 ]; then printf '[错误] 无法准备 SNI 检测依赖。\n' >&2; return 1; fi
        printf '[提示] 检测依赖不可用，改为手动输入 SNI。\n' >&2
        manual_reality_sni; return $?
    fi
    sni_work_dir=$(mktemp -d "${TMPDIR:-/tmp}/onebox-sni.XXXXXX") || return 1
    if ! check_reality_sni_curl; then
        if [ "$NON_INTERACTIVE" = 0 ]; then manual_reality_sni; return $?; fi
        return 1
    fi
    result=$(reality_sni_candidates "$sni_region" "$sni_categories" "$sni_hosts") || return 1
    [ -n "$result" ] || { printf '[错误] 所选地区与分类没有候选，请调整筛选条件。\n' >&2; return 1; }
    mapfile -t candidates <<< "$result"
    mkfifo "$sni_work_dir/poll" || return 1
    exec 9<>"$sni_work_dir/poll" || return 1
    sni_poll_open=1
    # A private worker session makes the parent watchdog independent of the TLS client.
    {
        printf '%s\n' '#!/bin/bash' 'set +m' 'marker="$4"; sni_curl_certinfo="$5"' \
            'trap '\''printf "%s\n" "$?" > "$marker"'\'' EXIT'
        declare -f valid_host reality_sni_allowed_host probe_reality_sni
        printf '%s\n' 'probe_reality_sni "$1" "$2" "$3"'
    } > "$sni_work_dir/worker.sh" || return 1
    set +m
    printf '检测 %s 个候选（地区=%s，分类=%s）：TLS 1.3、X25519、证书主机名、h2 和证书链。\n并发上限 %s，每站测速 %s 次取最小值，单次超时 %s 秒。\n' \
        "${#candidates[@]}" "$sni_region" "$sni_categories" "$sni_jobs" "$sni_samples" "$sni_timeout" >&2
    while [ "$batch_start" -lt "${#candidates[@]}" ]; do
        if ! onebox_safe_sni_jobs "$sni_jobs"; then
            printf '[错误] 剩余进程额度不足，停止扫描：%s。请释放资源或显式指定 --sni。\n' "$sni_pid_source" >&2
            return 1
        fi
        if [ "$sni_effective_jobs" != "$last_jobs" ]; then
            if [ "$sni_effective_jobs" -lt "$sni_jobs" ]; then
                printf '[提示] 根据剩余 PID 额度将并发从 %s 降至 %s：%s；为控制和清理保留余量。\n' "$sni_jobs" "$sni_effective_jobs" "$sni_pid_source" >&2
            fi
            last_jobs="$sni_effective_jobs"
        fi
        sni_pids=(); deadlines=(); sni_launch_abort=0
        # Defer exit until $! is recorded, so a signal during launch cannot orphan a worker.
        trap 'sni_launch_abort=130' INT
        trap 'sni_launch_abort=143' TERM
        for ((slot=0; slot<sni_effective_jobs && batch_start+slot<${#candidates[@]}; slot++)); do
            position=$((batch_start+slot))
            # With job control disabled, setsid execs Bash and $! is also the process group ID.
            setsid bash "$sni_work_dir/worker.sh" "${candidates[position]}" "$sni_samples" "$sni_timeout" \
                "$sni_work_dir/done-$position" "$sni_curl_certinfo" \
                >"$sni_work_dir/result-$position" 2>"$sni_work_dir/error-$position" < /dev/null 9>&- &
            sni_pids+=("$!")
            deadlines+=("$((SECONDS+sni_samples*sni_timeout+3))")
            [ "$sni_launch_abort" = 0 ] || break
        done
        trap 'exit 130' INT
        trap 'exit 143' TERM
        [ "$sni_launch_abort" = 0 ] || return "$sni_launch_abort"
        launched="${#sni_pids[@]}"; pending="$launched"
        while [ "$pending" -gt 0 ]; do
            for ((slot=0; slot<launched; slot++)); do
                worker="${sni_pids[slot]}"; [ -n "$worker" ] || continue
                position=$((batch_start+slot)); host="${candidates[position]}"; probe_rc=1
                if [ -s "$sni_work_dir/done-$position" ]; then
                    read -r probe_rc < "$sni_work_dir/done-$position" || :
                elif ! kill -0 "$worker" 2>/dev/null; then
                    probe_rc=1
                elif [ "$SECONDS" -lt "${deadlines[slot]}" ]; then
                    continue
                else
                    printf ' [超时] %s：父进程终止整组检测任务。\n' "$host" >&2
                fi
                stop_reality_sni_worker "$worker" || return 1
                sni_pids[slot]=''; pending=$((pending-1)); completed=$((completed+1))
                score=''; chain=''
                IFS=$'\t' read -r score chain < "$sni_work_dir/result-$position" || :
                if [ "$probe_rc" = 0 ] && [[ "$score" =~ ^[0-9]+$ && "$chain" =~ ^[0-9]+$ ]]; then
                    tier=0; [ "$chain" -le 3 ] || tier=1
                    [ "$chain" != 0 ] || tier=2
                    matches+=("$tier"$'\t'"$score"$'\t'"$chain"$'\t'"$host")
                    result="$chain 层"; [ "$chain" != 0 ] || result=未知
                    printf ' [%s/%s] %s：通过（证书链 %s）\n' "$completed" "${#candidates[@]}" "$host" "$result" >&2
                else
                    printf ' [%s/%s] %s：未通过或超时\n' "$completed" "${#candidates[@]}" "$host" >&2
                    if [ -s "$sni_work_dir/error-$position" ]; then
                        IFS= read -r result < "$sni_work_dir/error-$position" || :
                        printf '   %.240s\n' "$result" >&2
                    fi
                fi
            done
            if [ "$pending" -gt 0 ]; then IFS= read -r -t 0.1 -u 9 _ || :; fi
        done
        batch_start=$((batch_start+launched))
    done
    sni_pids=()
    if [ "${#matches[@]}" = 0 ]; then
        if [ "$NON_INTERACTIVE" = 1 ]; then
            printf '[错误] 没有通过 SNI 检测的候选；请检查出站网络、调整筛选条件，或用 --sni 显式指定域名。\n' >&2; return 1
        fi
        printf '[提示] 没有候选通过全部检测，改为手动输入。\n' >&2
        manual_reality_sni; return $?
    fi
    ranked=$(printf '%s\n' "${matches[@]}" | LC_ALL=C sort -k1,1n -k2,2n -k4,4) || return 1
    printf '\n候选 SNI（短证书链优先，同组按多次 TCP/TLS 建连最小耗时排序；通过 %s/%s）：\n' "${#matches[@]}" "${#candidates[@]}" >&2
    while IFS=$'\t' read -r tier score chain host; do
        hosts+=("$host"); index=$((index+1))
        result="约 $score ms"; [ "$score" != 2147483647 ] || result='耗时未测得'
        answer='短链'
        case "$tier" in 1) answer='长链备选，需验证兼容性' ;; 2) answer='链长度未知，需验证兼容性'; chain='未知' ;; esac
        printf ' %s) %s（%s，链 %s 层，%s）\n' "$index" "$host" "$result" "$chain" "$answer" >&2
    done <<< "$ranked"
    if [ "$NON_INTERACTIVE" = 1 ]; then
        printf '[完成] 自动选择排名第一的 SNI：%s。检测仅代表本机当前网络。\n' "${hosts[0]}" >&2
        printf '%s\n' "${hosts[0]}"; return 0
    fi
    printf ' 0) 手动输入\n检测无法保证所有客户端网络可用。\n' >&2
    while true; do
        ask "请选择 [0-$index，默认: 1]: " answer
        answer="${answer:-1}"
        if [ "$answer" = 0 ]; then manual_reality_sni; return $?; fi
        if [[ "$answer" =~ ^[1-9][0-9]{0,2}$ ]] && [ "$answer" -le "$index" ]; then
            printf '%s\n' "${hosts[answer-1]}"; return 0
        fi
        printf '[提示] 请输入有效编号。\n' >&2
    done
}

choose_reality_sni() (run_reality_sni_selection)

stop_sni_selection() {
    if [ -n "${SB_SNI_PID:-}" ]; then
        kill "$SB_SNI_PID" 2>/dev/null || :
        wait "$SB_SNI_PID" 2>/dev/null || :
        SB_SNI_PID=""
    fi
}

resolve_reality_sni() {
    local destination="$1" selection_file sni_resolution_value rc=0
    selection_file=$(mktemp "${TMPDIR:-/tmp}/onebox-sni-choice.XXXXXX") || return 1
    SB_OWNED_TEMP_FILES+=("$selection_file")
    # One explicit subshell: $! must identify the shell owning the cleanup trap.
    (run_reality_sni_selection) >"$selection_file" <&0 &
    SB_SNI_PID=$!
    wait "$SB_SNI_PID" || rc=$?
    SB_SNI_PID=""
    IFS= read -r sni_resolution_value < "$selection_file" || :
    rm -f -- "$selection_file"
    [ "$rc" = 0 ] || return "$rc"
    reality_sni_allowed_host "$sni_resolution_value" || return 1
    printf -v "$destination" '%s' "$sni_resolution_value"
}


confirm_http01_ready() {
    local confirmed=""
    echo 'HTTP-01 首次申请和后续自动续期都需要公网 80/TCP 可达，且验证时端口不能被其他程序占用。' >&2
    echo '本脚本不自动修改 80/TCP 防火墙规则。请维护长期放行；无法保证时请选择 DNS 验证。' >&2
    if check_port 80 tcp; then
        echo '本机 80/TCP 已被占用，取消 standalone 申请。' >&2
        return 1
    fi
    ask "已确认长期放行 80/TCP 并为续期保留端口？(y/n) [默认: n]: " confirmed
    case "$confirmed" in
        y|Y) return 0 ;;
        *) echo '已取消 HTTP-01 申请，可重新选择 DNS 验证。' >&2; return 1 ;;
    esac
}

ensure_acme_installed() {
    ensure_deps curl wget socat openssl tar gzip || return 1
    export LE_WORKING_DIR="$ACME_HOME"
    ensure_cron || return 1
    [ -f "$ACME_HOME/acme.sh" ] && return 0
    local stage installer failed=0
    mkdir -p /var/lib/onebox || return 1
    chmod 700 /var/lib/onebox || return 1
    stage=$(mktemp -d /var/lib/onebox/.acme-bootstrap.XXXXXX) || return 1
    SB_OWNED_TEMP_DIRS+=("$stage")
    installer="$stage/acme.sh"
    # Use acme.sh's argument parser directly; get.acme.sh treats its first arg as email.
    if ! fetch_url https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh "$installer"; then
        failed=1
    elif [ ! -s "$installer" ] || ! sh -n "$installer"; then
        failed=1
    elif ! (cd "$stage" && sh "$installer" --install-online --home "$ACME_HOME" --config-home "$ACME_HOME" --cert-home "$ACME_HOME" --no-profile); then
        failed=1
    elif [ ! -f "$ACME_HOME/acme.sh" ]; then
        failed=1
    fi
    rm -rf -- "$stage"
    if [ "$failed" != 0 ]; then
        echo '[错误] acme.sh 引导安装失败，请检查网络及安装日志。' >&2
        return 1
    fi
}

cert_remaining_days() {
    local cert="$1" raw_end iso_end end_ts
    command -v openssl >/dev/null 2>&1 || return 1
    raw_end=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -n "$raw_end" ] || return 1
    end_ts=$(date -d "$raw_end" +%s 2>/dev/null) || end_ts=""
    if [ -z "$end_ts" ]; then
        iso_end=$(printf '%s\n' "$raw_end" | awk '
            BEGIN {
                m["Jan"]="01"; m["Feb"]="02"; m["Mar"]="03"; m["Apr"]="04";
                m["May"]="05"; m["Jun"]="06"; m["Jul"]="07"; m["Aug"]="08";
                m["Sep"]="09"; m["Oct"]="10"; m["Nov"]="11"; m["Dec"]="12";
            }
            {
                if ($1 in m) printf "%04d-%s-%02d %s", $4, m[$1], $2, $3
            }')
        [ -n "$iso_end" ] && end_ts=$(date -u -d "$iso_end" +%s 2>/dev/null)
    fi
    [ -n "$end_ts" ] || return 1
    printf '%d\n' $(( (end_ts - $(date +%s)) / 86400 ))
}

cert_matches_host() {
    local result
    # OpenSSL 3.0 can return 0 for a mismatch; inspect the explicit match result.
    result=$(LC_ALL=C openssl x509 -in "$1" -noout -checkhost "$2" 2>&1) || return 1
    [[ "$result" == *'does match certificate'* ]]
}

apply_real_cert() {
    export LE_WORKING_DIR="$ACME_HOME"
    local NEW_DOMAIN
    NEW_DOMAIN=$(get_domain "请输入解析到本机的域名" "") || return 1

    local reuse=0
    local had_prior=0
    if [ -f "$ACME_HOME/acme.sh" ]; then
        local dconf
        dconf=$("$ACME_HOME/acme.sh" --info -d "${NEW_DOMAIN}" 2>/dev/null | sed -n 's/^DOMAIN_CONF=//p')
        local exist_cer=""
        if [ -n "$dconf" ]; then
            local ddir="${dconf%/*}"
            for c in "$ddir/fullchain.cer" "$ddir/${NEW_DOMAIN}.cer"; do
                [ -s "$c" ] && { exist_cer="$c"; break; }
            done
        fi
        [ -n "$exist_cer" ] && had_prior=1
        if [ -n "$exist_cer" ]; then
            local left_days=""
            left_days=$(cert_remaining_days "$exist_cer") || left_days=""
            if { [ -n "$left_days" ] && [ "$left_days" -gt 7 ]; } ||
               { [ -z "$left_days" ] && openssl x509 -in "$exist_cer" -noout -checkend 604800 >/dev/null 2>&1; }; then
                echo -e "\n${GREEN}检测到 ${NEW_DOMAIN} 已有有效证书，剩余 ${left_days:-大于7} 天。${PLAIN}"
                echo -e "${YELLOW}[提示] Let's Encrypt 对同一域名限制 168 小时内最多签发 5 次，建议直接复用。${PLAIN}"
                ask "是否复用现有证书？(y/n) [默认: y]: " ru
                [[ "${ru:-y}" == "y" || "${ru:-y}" == "Y" ]] && reuse=1
            fi
        fi
    fi

    if [ "$reuse" -eq 0 ]; then
        echo -e "\n请选择验证方式:"
        echo -e " 1) 80端口独立申请 - 需确保服务器80端口开放且未被占用"
        echo -e " 2) Cloudflare DNS API - 推荐，适合各类环境"
        local v_mode
        while true; do
            ask "请选择 [1-2]: " v_mode
            if [[ "$v_mode" == "1" || "$v_mode" == "2" ]]; then break; fi
        done

        ensure_acme_installed || return 1
        "$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1

        if [ "$v_mode" == "1" ]; then
            if ! confirm_http01_ready; then
                return 1
            fi
            local issue_ok=1
            if ! "$ACME_HOME/acme.sh" --issue -d "${NEW_DOMAIN}" --standalone --force; then
                issue_ok=0
            fi
            if [ "$issue_ok" -eq 0 ]; then
                echo -e "${RED}[错误] 申请失败！请检查域名解析和 80 端口是否连通。${PLAIN}"
                return 1
            fi
        else
            if [ -n "${CF_Token:-}" ]; then
                CF_Token="$CF_Token" "$ACME_HOME/acme.sh" --issue --dns dns_cf -d "$NEW_DOMAIN" --force || return 1
            else
            local NEW_CF_Key=""
            while true; do
                ask "请输入 Cloudflare Global API Key: " NEW_CF_Key
                if [[ "$NEW_CF_Key" =~ ^[A-Za-z0-9]+$ ]]; then break; fi
                echo -e "${RED}[错误] 错误：API Key 格式不正确！${PLAIN}" >&2
                [ "$NON_INTERACTIVE" = 0 ] || return 1
            done

            local NEW_CF_Email=""
            while true; do
                ask "请输入 Cloudflare 邮箱: " NEW_CF_Email
                if [[ "$NEW_CF_Email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then break; fi
                echo -e "${RED}[错误] 错误：邮箱格式不正确，请重新输入！${PLAIN}" >&2
                [ "$NON_INTERACTIVE" = 0 ] || return 1
            done

            if ! CF_Key="${NEW_CF_Key}" CF_Email="${NEW_CF_Email}" "$ACME_HOME/acme.sh" --issue --dns dns_cf -d "${NEW_DOMAIN}" --force; then
                echo -e "${RED}[错误] 申请失败！请检查 CF API 是否正确，或该域名已达 Let's Encrypt 签发频率上限。${PLAIN}"
                return 1
            fi
            fi
        fi
    fi

    deploy_real_cert "$NEW_DOMAIN" "$had_prior" || return 1
    echo -e "${GREEN}[完成] 域名证书申请并安装完成！${PLAIN}"
    return 0
}

deploy_real_cert() {
    local domain="$1" had_prior="$2"
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ && "$domain" != .* && "$domain" != *..* ]] || return 1
    (
        umask 077
        local stage changed=0 completed=0 active=0 reload target i
        local -a targets=()
        stage=$(mktemp -d "$CERT_DIR/.real-deploy.XXXXXX") || exit 1
        targets=("$CERT_DIR/real.cer" "$CERT_DIR/real.key" "$SECRETS_FILE"
                 "$ACME_HOME/$domain/$domain.conf"
                 "$ACME_HOME/${domain}_ecc/$domain.conf")
        if [ "$SERVICE_MANAGER" = openrc ]; then
            rc-service onebox status >/dev/null 2>&1 && active=1
            reload="if [ -e /etc/init.d/onebox ] && rc-service onebox status >/dev/null 2>&1; then rc-service onebox restart >/dev/null 2>&1; fi"
        else
            systemctl is-active --quiet onebox 2>/dev/null && active=1
            reload="if systemctl is-active --quiet onebox 2>/dev/null; then systemctl restart onebox >/dev/null 2>&1; fi"
        fi
        real_restore_one() {
            local index="$1" path="$2" tmp
            if [ -f "$stage/$index.absent" ]; then rm -f -- "$path"; return $?; fi
            tmp=$(mktemp "${path}.restore.XXXXXX") || return 1
            if cp -p "$stage/$index" "$tmp" && mv -f "$tmp" "$path"; then return 0; fi
            rm -f "$tmp"; return 1
        }
        real_finish() {
            local rc=$? failed=0 j
            trap - EXIT INT TERM
            if [ "$changed" = 1 ] && [ "$completed" = 0 ]; then
                for j in "${!targets[@]}"; do real_restore_one "$j" "${targets[$j]}" || failed=1; done
                if [ "$failed" = 0 ]; then
                    if [ "$active" = 1 ]; then
                        if [ "$SERVICE_MANAGER" = openrc ]; then rc-service onebox restart || failed=1
                        else systemctl restart onebox || failed=1; fi
                    else
                        stop_sing_box_if_present || failed=1
                    fi
                fi
            fi
            if [ "$failed" != 0 ]; then
                printf '域名证书恢复失败，备份保留: %s\n' "$stage" >&2
                exit 1
            fi
            rm -rf -- "$stage"
            exit "$rc"
        }
        trap real_finish EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        for i in "${!targets[@]}"; do
            target="${targets[$i]}"
            [ ! -L "$target" ] || exit 1
            if [ -e "$target" ]; then
                [ -f "$target" ] && cp -p "$target" "$stage/$i" || exit 1
            else touch "$stage/$i.absent" || exit 1; fi
        done
        changed=1
        if ! "$ACME_HOME/acme.sh" --installcert -d "$domain" \
            --fullchainpath "$CERT_DIR/real.cer" --keypath "$CERT_DIR/real.key" \
            --reloadcmd "$reload"; then
            echo -e "${RED}[错误] 证书部署命令失败，未完成安装。${PLAIN}" >&2
            exit 1
        fi
        openssl x509 -in "$CERT_DIR/real.cer" -noout -checkend 0 >/dev/null &&
        cert_matches_host "$CERT_DIR/real.cer" "$domain" &&
        openssl pkey -in "$CERT_DIR/real.key" -check -noout >/dev/null &&
        openssl x509 -in "$CERT_DIR/real.cer" -pubkey -noout > "$stage/cert.pub" &&
        openssl pkey -in "$CERT_DIR/real.key" -pubout > "$stage/key.pub" &&
        cmp -s "$stage/cert.pub" "$stage/key.pub" || exit 1
        chmod 644 "$CERT_DIR/real.cer" && chmod 600 "$CERT_DIR/real.key" || exit 1
        save_secret REAL_DOMAIN "$domain" || exit 1
        if [ "$had_prior" = 1 ]; then save_secret REAL_CERT_OWNED 0 || exit 1
        else save_secret REAL_CERT_OWNED 1 || exit 1; fi
        completed=1
    )
}

generate_self_cert() {
    ensure_deps openssl || return 1
    local NEW_DOMAIN
    NEW_DOMAIN=$(get_domain "请输入伪装域名" "bing.com") || return 1
    echo -e "${CYAN}[信息] 正在生成自签证书...${PLAIN}"
    (
        umask 077
        local stage changed=0 completed=0
        stage=$(mktemp -d "$CERT_DIR/.self-cert.XXXXXX") || exit 1
        cert_restore_one() {
            local name="$1" target="$2" tmp
            if [ -f "$stage/$name.absent" ]; then
                rm -f "$target"
            else
                tmp=$(mktemp "${target}.restore.XXXXXX") || return 1
                if cp -p "$stage/$name" "$tmp" && mv -f "$tmp" "$target"; then return 0; fi
                rm -f "$tmp"; return 1
            fi
        }
        cert_finish() {
            local rc=$? restore_failed=0
            trap - EXIT INT TERM
            if [ "$changed" = 1 ] && [ "$completed" = 0 ]; then
                cert_restore_one old.cer "$CERT_DIR/self.cer" || restore_failed=1
                cert_restore_one old.key "$CERT_DIR/self.key" || restore_failed=1
                cert_restore_one old.secrets "$SECRETS_FILE" || restore_failed=1
            fi
            if [ "$restore_failed" = 1 ]; then
                printf '自签证书恢复失败，备份保留在 %s\n' "$stage" >&2
                exit 1
            fi
            rm -rf "$stage"
            exit "$rc"
        }
        trap cert_finish EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        cert_backup_one() {
            local source="$1" name="$2"
            [ ! -L "$source" ] || return 1
            if [ -e "$source" ]; then cp -p "$source" "$stage/$name"; else touch "$stage/$name.absent"; fi
        }
        cert_backup_one "$CERT_DIR/self.cer" old.cer &&
        cert_backup_one "$CERT_DIR/self.key" old.key &&
        cert_backup_one "$SECRETS_FILE" old.secrets || exit 1
        if ! openssl req -x509 -nodes -days 36500 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "$stage/new.key" -out "$stage/new.cer" -subj "/CN=${NEW_DOMAIN}" \
            -addext "subjectAltName=DNS:${NEW_DOMAIN}"; then
            echo -e "${RED}[错误] 生成自签证书失败！请查看上方报错信息。${PLAIN}" >&2
            exit 1
        fi
        openssl x509 -in "$stage/new.cer" -noout -checkend 0 >/dev/null &&
        openssl pkey -in "$stage/new.key" -check -noout >/dev/null &&
        openssl x509 -in "$stage/new.cer" -pubkey -noout > "$stage/cert.pub" &&
        openssl pkey -in "$stage/new.key" -pubout > "$stage/key.pub" &&
        cmp -s "$stage/cert.pub" "$stage/key.pub" || exit 1
        chmod 644 "$stage/new.cer" && chmod 600 "$stage/new.key" || exit 1
        changed=1
        mv -f "$stage/new.key" "$CERT_DIR/self.key" &&
        mv -f "$stage/new.cer" "$CERT_DIR/self.cer" &&
        save_secret SELF_DOMAIN "$NEW_DOMAIN" || exit 1
        completed=1
        echo -e "${GREEN}[完成] 自签证书生成完毕！${PLAIN}"
    )
}

cert_manage() {
    while true; do
        ui_clear
        echo -e "选择: 证书管理\n"
        echo -e " 1) 重新申请域名证书"
        echo -e " 2) 重新生成自签证书"
        echo -e " 3) 查看证书与自动续期状态"
        echo -e " 0) 返回\n"

        load_secrets
        local cert_idx
        ask "请选择 [0-3]: " cert_idx
        case "$cert_idx" in
            1) apply_real_cert; pause ;;
            2) generate_self_cert; pause ;;
            3)
                echo -e "\n------------- 域名证书 -------------"
                if [ -s "$CERT_DIR/real.cer" ]; then
                    echo -e "绑定的域名\t: ${GREEN}${REAL_DOMAIN}${PLAIN}"
                    echo -e "证书路径\t: ${GREEN}$CERT_DIR/real.cer${PLAIN}"
                    if crontab -l 2>/dev/null | grep -q "acme.sh"; then
                        echo -e "${YELLOW}[提示] 检测到 acme.sh 定时任务；尚未验证 cron 服务、此域名的续期记录及最近执行结果。${PLAIN}"
                    else
                        echo -e "${RED}[错误] 警告: 未发现自动续期任务！${PLAIN}"
                    fi
                else
                    echo -e "${YELLOW}[提示] 当前未安装域名证书。${PLAIN}"
                fi
                echo -e "\n------------- 自签证书 -------------"
                if [ -s "$CERT_DIR/self.cer" ]; then
                    echo -e "伪装域名\t: ${GREEN}${SELF_DOMAIN}${PLAIN}"
                    echo -e "证书路径\t: ${GREEN}$CERT_DIR/self.cer${PLAIN}"
                else
                    echo -e "${YELLOW}[提示] 当前未生成自签证书。${PLAIN}"
                fi
                echo -e "------------------------------------"
                pause
                ;;
            0) return ;;
            *) echo -e "${RED}[错误] 输入错误，请重新选择!${PLAIN}"; sleep 1 ;;
        esac
    done
}

prompt_cert_type() {
    echo -e "\n请选择该节点使用的证书类型:"
    echo -e " 1) 域名证书"
    echo -e " 2) 自签证书"
    local c_idx
    while true; do
        ask "请选择 [1-2]: " c_idx
        case "$c_idx" in
            1)
                if [ "$NON_INTERACTIVE" = 1 ] && [ -s "$CERT_DIR/real.cer" ] &&
                   ! cert_matches_host "$CERT_DIR/real.cer" "$CLI_DOMAIN"; then
                    printf '[错误] 当前真实证书与 --domain 不匹配；请先用 cert 命令更新共享证书。\n' >&2
                    return 1
                fi
                if [ ! -s "$CERT_DIR/real.cer" ] || [ ! -s "$CERT_DIR/real.key" ]; then
                    echo -e "${YELLOW}[提示] 未检测到有效域名证书，需要先申请...${PLAIN}"
                    if ! apply_real_cert; then return 1; fi
                fi
                SEL_CERT="$CERT_DIR/real.cer"
                SEL_KEY="$CERT_DIR/real.key"
                break ;;
            2)
                if [ "$NON_INTERACTIVE" = 1 ] && [ -n "$CLI_SNI" ] && [ -s "$CERT_DIR/self.cer" ] &&
                   ! cert_matches_host "$CERT_DIR/self.cer" "$CLI_SNI"; then
                    printf '[错误] 当前自签证书与 --sni 不匹配；请先用 cert 命令更新共享证书。\n' >&2
                    return 1
                fi
                if [ ! -s "$CERT_DIR/self.cer" ] || [ ! -s "$CERT_DIR/self.key" ]; then
                    echo -e "${YELLOW}[提示] 未检测到有效自签证书，需要先生成...${PLAIN}"
                    if ! generate_self_cert; then return 1; fi
                fi
                SEL_CERT="$CERT_DIR/self.cer"
                SEL_KEY="$CERT_DIR/self.key"
                break ;;
            *) echo -e "${RED}[错误] 输入错误！${PLAIN}" ;;
        esac
    done
    return 0
}

get_uuid() {
    local val
    while true; do
        if [ "$NON_INTERACTIVE" = 1 ]; then val="${CLI_UUID:-}"
        else ask "请输入UUID [默认随机]: " val; fi
        [ -n "$val" ] || val=$(/usr/local/lib/onebox/sing-box generate uuid) || return 1
        if [[ "$val" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            break
        else
            echo -e "${RED}[错误] 错误：输入的格式不规范！必须是标准 UUID 格式。${PLAIN}" >&2
            [ "$NON_INTERACTIVE" = 0 ] || return 1
        fi
    done
    printf 'UUID: %b%s%b\n' "$GREEN" "$val" "$PLAIN" >&2
    printf '%s\n' "$val"
}

get_pass() {
    local val
    while true; do
        if [ "$NON_INTERACTIVE" = 1 ]; then val="${CLI_PASSWORD:-}"
        else ask "请输入密码(支持特殊符号,会自动安全编码) [默认随机]: " val; fi
        [ -n "$val" ] || val=$(/usr/local/lib/onebox/sing-box generate rand --hex 16) || return 1
        if [[ "$val" =~ [^[:space:]] ]]; then
            break
        else
            echo -e "${RED}[错误] 错误：密码不能全为空白字符！${PLAIN}" >&2
            [ "$NON_INTERACTIVE" = 0 ] || return 1
        fi
    done
    printf '密码: %b%s%b\n' "$GREEN" "$val" "$PLAIN" >&2
    printf '%s\n' "$val"
}
get_ss_method() {
    if [ "$NON_INTERACTIVE" = 1 ]; then printf '%s\n' "$CLI_METHOD"; return 0; fi
    local METHODS=("aes-128-gcm" "aes-256-gcm" "chacha20-ietf-poly1305" "2022-blake3-aes-128-gcm" "2022-blake3-aes-256-gcm" "2022-blake3-chacha20-poly1305")
    echo -e "选择加密方式:" >&2
    local i
    for i in "${!METHODS[@]}"; do
        echo -e " $((i + 1))) ${METHODS[$i]}" >&2
    done
    echo -e "${YELLOW}[提示] 提示: 4/5/6 为 SIP022 (2022) 方法，密码将自动生成 base64 密钥${PLAIN}" >&2
    local idx
    while true; do
        ask "请选择 [1-${#METHODS[@]}] [默认: 1]: " idx
        idx=${idx:-1}
        if [[ "$idx" =~ ^[1-9][0-9]*$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#METHODS[@]}" ]; then
            echo "${METHODS[$((idx - 1))]}"
            return
        fi
        echo -e "${RED}[错误] 输入错误，请重新选择！${PLAIN}" >&2
    done
}

get_ss_password() {
    local method=$1
    case "$method" in
        2022-blake3-aes-128-gcm)  /usr/local/lib/onebox/sing-box generate rand --base64 16 ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) /usr/local/lib/onebox/sing-box generate rand --base64 32 ;;
        *)  /usr/local/lib/onebox/sing-box generate rand --hex 16 ;;
    esac
}

get_ss_pass_valid() {
    local method="$1" pass="$2" size
    case "$method" in
        2022-blake3-aes-128-gcm) size=16 ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) size=32 ;;
        *) [[ "$pass" =~ [^[:space:]] ]]; return ;;
    esac
    [[ "$pass" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
    (set -o pipefail; printf '%s' "$pass" | base64 -d >/dev/null 2>&1) || return 1
    [ "$(printf '%s' "$pass" | base64 -d 2>/dev/null | wc -c)" -eq "$size" ]
}

get_unique_tag() {
    local base_tag=$1
    local counter=2
    local final_tag=$base_tag
    while jq -e --arg tag "$final_tag" '.inbounds[] | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; do
        final_tag="${base_tag}-${counter}"
        ((counter++))
    done
    echo "$final_tag"
}

node_read() {
    jq -j --arg tag "$1" '
      .inbounds[] | select(.tag==$tag) | [
      .type,
      (.listen_port|tostring),
      (.tls.certificate_path // ""),
      (.users[0].uuid // ""),
      (if .type == "shadowsocks" then .password else .users[0].password end // ""),
      (.tls.server_name // ""),
      (.tls.reality.short_id[0] // ""),
      (if .tls.reality.enabled == true then "1" else "0" end),
      (if .transport.type == "ws" then "1" else "0" end),
      (.method // "")] | .[] | tostring + "\u0000"
    ' "$CONFIG_FILE" 2>/dev/null
}

read_node_fields() {
    local tmp field
    tmp=$(mktemp "${TMPDIR:-/tmp}/onebox-node.XXXXXX") || return 1
    SB_OWNED_TEMP_FILES+=("$tmp")
    if ! node_read "$1" > "$tmp"; then rm -f "$tmp"; return 1; fi
    M=()
    while IFS= read -r -d '' field; do M+=("$field"); done < "$tmp"
    rm -f "$tmp"
    [ "${#M[@]}" = 10 ]
}

read_all_tags() {
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/onebox-tags.XXXXXX") || return 1
    SB_OWNED_TEMP_FILES+=("$tmp")
    if ! jq -r '.inbounds[] | select(.tag != null and .tag != "dns-in") | .tag' "$CONFIG_FILE" > "$tmp"; then rm -f "$tmp"; return 1; fi
    mapfile -t TAGS < "$tmp"
    rm -f "$tmp"
}

resolve_conn() {
    local cert_path=$1
    local ip=$2
    CONN_ADDR=$ip
    CONN_INSECURE=1
    CONN_SNI=""
    if [[ "$cert_path" == *"/real.cer" ]]; then
        if [ -z "$REAL_DOMAIN" ] && [ -s "$cert_path" ] && command -v openssl >/dev/null 2>&1; then
            REAL_DOMAIN=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,]*\).*/\1/p' | tr -d ' ')
            [ -n "$REAL_DOMAIN" ] && save_secret "REAL_DOMAIN" "$REAL_DOMAIN"
        fi
        CONN_ADDR=$REAL_DOMAIN
        CONN_INSECURE=0
        CONN_SNI=$REAL_DOMAIN
    elif [[ "$cert_path" == *"/self.cer" ]]; then
        CONN_SNI=${SELF_DOMAIN:-bing.com}
    fi
}

build_share_url() {
    local TAG=$1
    local IP=$2
    load_secrets

    local -a M=()
    read_node_fields "$TAG" || { printf '[错误] 读取节点 %s 失败。\n' "$TAG" >&2; return 1; }
    local TYPE=${M[0]} PORT=${M[1]} CERT_PATH=${M[2]}
    local N_UUID=${M[3]} N_PASS=${M[4]} SNI=${M[5]} SID=${M[6]}
    local IS_REALITY=${M[7]} IS_WS=${M[8]} SS_METHOD=${M[9]}

    resolve_conn "$CERT_PATH" "$IP"
    local SNI_URL="${CONN_SNI:+&sni=${CONN_SNI}}"

    local IP_URI
    IP_URI=$(wrap_ipv6 "$IP")
    local CONN_ADDR_URI
    CONN_ADDR_URI=$(wrap_ipv6 "$CONN_ADDR")

    case "$TYPE" in
        vless)
            if [ "$IS_REALITY" == "1" ]; then
                if [ -z "$IP" ]; then echo -e "${RED}[错误] [获取公网IP异常，无法生成 VLESS-REALITY 链接]${PLAIN}" >&2; return 1; fi
                local var_name="REALITY_PUB_${PORT}"
                local PUB="${!var_name}"
                printf '%s\n' "vless://${N_UUID}@${IP_URI}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#${TAG}"
            elif [ "$IS_WS" == "1" ]; then
                local var_ip="ARGO_IP_${PORT}"
                local var_dom="ARGO_DOMAIN_${PORT}"
                local A_IP="${!var_ip}"
                local A_DOM="${!var_dom}"
                if [ -z "$A_IP" ]; then echo -e "${RED}[错误] [无法读取 Argo IP，无法生成链接]${PLAIN}" >&2; return 1; fi
                if [ -z "$A_DOM" ]; then echo '[错误] 缺少 Argo 隧道域名，无法生成包含 Host/SNI 的链接。' >&2; return 1; fi
                local A_IP_URI
                A_IP_URI=$(wrap_ipv6 "$A_IP")
                printf '%s\n' "vless://${N_UUID}@${A_IP_URI}:443?encryption=none&security=tls&type=ws&host=${A_DOM}&path=%2Fargo&sni=${A_DOM}#${TAG}"
            fi
            ;;
        hysteria2)
            if [ -z "$CONN_ADDR" ]; then echo -e "${RED}[错误] [获取连接地址失败，无法生成 Hysteria2 链接]${PLAIN}" >&2; return 1; fi
            local AUTH_ENC
            AUTH_ENC=$(url_encode "$N_PASS")
            printf '%s\n' "hysteria2://${AUTH_ENC}@${CONN_ADDR_URI}:${PORT}?security=tls&alpn=h3&insecure=${CONN_INSECURE}&allowInsecure=${CONN_INSECURE}${SNI_URL}#${TAG}"
            ;;
        tuic)
            if [ -z "$CONN_ADDR" ]; then echo -e "${RED}[错误] [获取连接地址失败，无法生成 TUIC 链接]${PLAIN}" >&2; return 1; fi
            local T_UUID_ENC
            T_UUID_ENC=$(url_encode "$N_UUID")
            local T_PASS_ENC
            T_PASS_ENC=$(url_encode "$N_PASS")
            printf '%s\n' "tuic://${T_UUID_ENC}:${T_PASS_ENC}@${CONN_ADDR_URI}:${PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&insecure=${CONN_INSECURE}&allowInsecure=${CONN_INSECURE}${SNI_URL}#${TAG}"
            ;;
        anytls)
            if [ -z "$CONN_ADDR" ]; then echo -e "${RED}[错误] [获取连接地址失败，无法生成 AnyTLS 链接]${PLAIN}" >&2; return 1; fi
            local AUTH_ENC
            AUTH_ENC=$(url_encode "$N_PASS")
            printf '%s\n' "anytls://${AUTH_ENC}@${CONN_ADDR_URI}:${PORT}?insecure=${CONN_INSECURE}&allowInsecure=${CONN_INSECURE}${SNI_URL}#${TAG}"
            ;;
        shadowsocks)
            if [ -z "$CONN_ADDR" ]; then echo -e "${RED}[错误] [获取连接地址失败，无法生成 Shadowsocks 链接]${PLAIN}" >&2; return 1; fi
            local SS_CRED
            if [[ "$SS_METHOD" == 2022-* ]]; then
                SS_CRED="$(url_encode "$SS_METHOD"):$(url_encode "$N_PASS")"
            else
                SS_CRED=$(printf '%s' "${SS_METHOD}:${N_PASS}" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
            fi
            printf '%s\n' "ss://${SS_CRED}@${CONN_ADDR_URI}:${PORT}#${TAG}"
            ;;
    esac
}

print_config_detail() {
    local TAG=$1
    local IP=""
    IP_LOOKUP_SKIPPED=0
    load_secrets

    local -a M=()
    read_node_fields "$TAG" || { printf '[错误] 读取节点 %s 失败。\n' "$TAG" >&2; return 1; }
    local TYPE=${M[0]} PORT=${M[1]} CERT_PATH=${M[2]}
    local N_UUID=${M[3]} N_PASS=${M[4]} SNI=${M[5]} SID=${M[6]}
    local IS_REALITY=${M[7]} IS_WS=${M[8]} SS_METHOD=${M[9]}

    if [ "$IS_WS" != 1 ] && [[ "$CERT_PATH" != */real.cer ]]; then get_ip || :; IP=$GLOBAL_IP; fi

    resolve_conn "$CERT_PATH" "$IP"
    local INSECURE_TEXT="true"
    [ "$CONN_INSECURE" -eq 0 ] && INSECURE_TEXT="false"
    local SNI_VAL=$CONN_SNI

    echo -e "\n-------------- ${YELLOW}$TAG${PLAIN} -------------"
    echo -e "协议 (protocol)\t\t\t= $TYPE"

    case "$TYPE" in
        vless)
            if [ "$IS_REALITY" == "1" ]; then
                local var_name="REALITY_PUB_${PORT}"
                local PUB="${!var_name}"
                local IP_DISP="$IP"
                [[ "$IP_DISP" == *:* ]] && IP_DISP="[$IP_DISP]"
                echo -e "地址 (address)\t\t\t= ${IP_DISP:-[获取公网IP失败]}"
                echo -e "端口 (port)\t\t\t= $PORT"
                echo -e "用户ID (id)\t\t\t= $N_UUID"
                echo -e "流控 (flow)\t\t\t= xtls-rprx-vision"
                echo -e "传输层安全 (TLS)\t\t= reality"
                echo -e "伪装域名 (sni)\t\t\t= $SNI"
                echo -e "公钥 (pbk)\t\t\t= $PUB"
                echo -e "ShortId (sid)\t\t\t= $SID"
            elif [ "$IS_WS" == "1" ]; then
                local var_ip="ARGO_IP_${PORT}"
                local var_dom="ARGO_DOMAIN_${PORT}"
                local A_IP="${!var_ip}"
                local A_DOM="${!var_dom}"
                local A_IP_DISP="$A_IP"
                [[ "$A_IP_DISP" == *:* ]] && A_IP_DISP="[$A_IP_DISP]"
                echo -e "地址 (address)\t\t\t= $A_IP_DISP"
                echo -e "端口 (port)\t\t\t= 443"
                echo -e "用户ID (id)\t\t\t= $N_UUID"
                echo -e "传输协议 (network)\t\t= ws"
                echo -e "传输层安全 (TLS)\t\t= tls"
                echo -e "伪装域名 (sni)\t\t\t= $A_DOM"
                echo -e "请求主机 (host)\t\t\t= $A_DOM"
                echo -e "路径 (path)\t\t\t= /argo"
            fi
            ;;
        hysteria2)
            local CONN_ADDR_DISP="$CONN_ADDR"
            [[ "$CONN_ADDR_DISP" == *:* ]] && CONN_ADDR_DISP="[$CONN_ADDR_DISP]"
            echo -e "地址 (address)\t\t\t= ${CONN_ADDR_DISP:-[获取目标地址失败]}"
            echo -e "端口 (port)\t\t\t= $PORT"
            printf '密码 (password)\t\t\t= %s\n' "$N_PASS"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "应用层协议协商 (Alpn)\t\t= h3"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            [ -n "$SNI_VAL" ] && echo -e "伪装域名 (sni)\t\t\t= $SNI_VAL"
            ;;
        tuic)
            local CONN_ADDR_DISP="$CONN_ADDR"
            [[ "$CONN_ADDR_DISP" == *:* ]] && CONN_ADDR_DISP="[$CONN_ADDR_DISP]"
            echo -e "地址 (address)\t\t\t= ${CONN_ADDR_DISP:-[获取目标地址失败]}"
            echo -e "端口 (port)\t\t\t= $PORT"
            echo -e "用户ID (id)\t\t\t= $N_UUID"
            printf '密码 (password)\t\t\t= %s\n' "$N_PASS"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "应用层协议协商 (Alpn)\t\t= h3"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            echo -e "拥塞控制算法 (congestion_control)= bbr"
            [ -n "$SNI_VAL" ] && echo -e "伪装域名 (sni)\t\t\t= $SNI_VAL"
            ;;
        anytls)
            local CONN_ADDR_DISP="$CONN_ADDR"
            [[ "$CONN_ADDR_DISP" == *:* ]] && CONN_ADDR_DISP="[$CONN_ADDR_DISP]"
            echo -e "地址 (address)\t\t\t= ${CONN_ADDR_DISP:-[获取目标地址失败]}"
            echo -e "端口 (port)\t\t\t= $PORT"
            printf '密码 (password)\t\t\t= %s\n' "$N_PASS"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            [ -n "$SNI_VAL" ] && echo -e "伪装域名 (sni)\t\t\t= $SNI_VAL"
            ;;
        shadowsocks)
            local CONN_ADDR_DISP="$CONN_ADDR"
            [[ "$CONN_ADDR_DISP" == *:* ]] && CONN_ADDR_DISP="[$CONN_ADDR_DISP]"
            echo -e "地址 (address)\t\t\t= ${CONN_ADDR_DISP:-[获取目标地址失败]}"
            echo -e "端口 (port)\t\t\t= $PORT"
            printf '密码 (password)\t\t\t= %s\n' "$N_PASS"
            echo -e "加密方式 (method)\t\t= ${SS_METHOD:-未知}"
            echo -e "传输模式 (mode)\t\t= tcp+udp"
            ;;
    esac

    echo -e "------------- 链接 (URL) -------------"
    if [ "$IP_LOOKUP_SKIPPED" = 1 ]; then
        printf '[提示] 进程额度不足，已跳过分享链接生成；稍后重试，或用 onebox links --address 指定地址。\n'
    else
        build_share_url "$TAG" "$IP"
    fi

    if [ "$INSECURE_TEXT" == "true" ] && [ "$IS_REALITY" != "1" ] && [ "$IS_WS" != "1" ] && [ "$TYPE" != "shadowsocks" ]; then
        echo -e "\n${YELLOW}警告! 此节点使用自签名证书，请确保客户端已开启「跳过证书验证」！${PLAIN}\n"
    fi
}

select_inbound() {
    if [ "$NON_INTERACTIVE" = 1 ]; then
        TAG="$CLI_TAG"
        jq -e --arg tag "$TAG" '.inbounds[] | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null || return 1
        return 0
    fi
    local old_IFS=$IFS
    IFS=$'\n'
    read_all_tags || return 1
    IFS=$old_IFS

    if [ ${#TAGS[@]} -eq 0 ]; then
        echo -e "${RED}[错误] 未添加节点配置！${PLAIN}"
        pause
        return 1
    fi
    for i in "${!TAGS[@]}"; do
        echo -e " $((i + 1))) ${CYAN}${TAGS[$i]}${PLAIN}"
    done
    echo -e " 0) 返回\n"

    while true; do
        ask "请选择 [0-${#TAGS[@]}]: " idx
        if [[ -z "$idx" ]] || [[ "$idx" == "0" ]]; then return 1; fi
        if ! [[ "$idx" =~ ^[1-9][0-9]*$ ]] || [ "$idx" -gt "${#TAGS[@]}" ]; then
            echo -e "${RED}[错误] 输入错误，请重新选择！${PLAIN}"
            continue
        fi
        ((idx--))
        TAG=${TAGS[$idx]}
        return 0
    done
}

warn_port_shared() {
    local port=$1 proto=$2 self_tag=$3
    [ -z "$proto" ] && return 1
    local other
    other=$(jq -r --argjson p "$port" --arg self "${self_tag:-}" '
      .inbounds[]
      | select(.listen_port == $p)
      | select(.tag != $self)
      | "\(.tag)|\(.type)|\(if .transport.type == "ws" then "ws" else "" end)"
    ' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$other" ] && return 1

    local found=1
    while IFS='|' read -r o_tag o_type _o_ws; do
        [ -z "$o_tag" ] && continue
        local o_proto=""
        case "$o_type" in
            hysteria2|tuic) o_proto="udp" ;;
            anytls|vless)   o_proto="tcp" ;;
            shadowsocks)    o_proto="both" ;;
        esac
        if [ -n "$o_proto" ] && [ "$o_proto" != "both" ] && [ "$proto" != "both" ] && [ "$o_proto" != "$proto" ]; then
            echo -e "\n${YELLOW}提示: 端口 ${port} 已被节点 ${o_tag} 使用 (${o_proto^^})，本节点用的是 ${proto^^}。${PLAIN}"
            echo -e "${YELLOW}[提示] 内核允许 TCP/UDP 同号共存，但请确认防火墙与云服务商/NAT 端口映射${PLAIN}"
            echo -e "${YELLOW}[提示] 对 ${proto^^} 和 ${o_proto^^} 两种协议都放行了 ${port}，否则其中一个节点会连不上。${PLAIN}"
            found=0
        fi
    done <<< "$other"
    return $found
}

add_config() {
    while true; do
        if [ "$NON_INTERACTIVE" = 0 ]; then
        ui_clear
        echo -e "请选择协议:\n"
        echo -e " 1) VLESS-REALITY"
        echo -e " 2) Hysteria2"
        echo -e " 3) TUIC"
        echo -e " 4) AnyTLS"
        echo -e " 5) VLESS-Argo"
        echo -e " 6) Shadowsocks"
        echo -e " 0) 返回\n"
        fi

        local proto_idx
        while true; do
            ask "请选择 [0-6]: " proto_idx
            if [[ "$proto_idx" =~ ^[0-6]$ ]]; then break; fi
            echo -e "${RED}[错误] 输入错误，请重新选择！${PLAIN}"
        done
        [ "$proto_idx" == "0" ] && return

        load_secrets
        local DEF_PORT
        if [ -n "${CLI_PORT:-}" ] && [ "$NON_INTERACTIVE" = 1 ]; then DEF_PORT="$CLI_PORT"
        else DEF_PORT=$(rand_port) || return 1; fi
        local PORT

        local f_proto=""
        local check_proto="tcp"
        if [[ "$proto_idx" == "1" || "$proto_idx" == "4" ]]; then f_proto="tcp"; check_proto="tcp"
        elif [[ "$proto_idx" == "2" || "$proto_idx" == "3" ]]; then f_proto="udp"; check_proto="udp"
        elif [ "$proto_idx" == "5" ]; then f_proto=""; check_proto="tcp"
        elif [ "$proto_idx" == "6" ]; then f_proto="both"; check_proto="both"
        fi

        while true; do
            ask "请输入监听端口 [默认: $DEF_PORT]: " PORT
            PORT=${PORT:-$DEF_PORT}
            if ! [[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                echo -e "${RED}[错误] 端口必须为 1-65535 之间的数字${PLAIN}"; if [ "$NON_INTERACTIVE" = 1 ]; then return 1; fi; continue
            fi
            if check_port "$PORT" "$check_proto"; then
                echo -e "${RED}[错误] 错误! 端口 ${PORT} 已被占用！${PLAIN}"; if [ "$NON_INTERACTIVE" = 1 ]; then return 1; fi; continue
            fi
            break
        done
        echo -e "使用: ${GREEN}${PORT}${PLAIN}"
        warn_port_shared "$PORT" "$check_proto"

        local raw_hostname
        raw_hostname=$(hostname 2>/dev/null || echo "vps")
        local HOST_NAME
        HOST_NAME=$(echo "$raw_hostname" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')
        [ -z "$HOST_NAME" ] && HOST_NAME="vps"

        local DEF_TAG=""
        case "$proto_idx" in
            1) DEF_TAG="vless-reality" ;;
            2) DEF_TAG="hysteria2" ;;
            3) DEF_TAG="tuic" ;;
            4) DEF_TAG="anytls" ;;
            5) DEF_TAG="vless-argo" ;;
            6) DEF_TAG="shadowsocks" ;;
        esac
        DEF_TAG="${DEF_TAG}-${HOST_NAME}"

        local input_tag
        while true; do
            ask "请输入节点名称 [默认: $DEF_TAG]: " input_tag
            input_tag=${input_tag:-$DEF_TAG}
            input_tag=${input_tag// /-}
            if [[ "$input_tag" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                break
            else
                echo -e "${RED}[错误] 错误：节点名称仅限字母、数字、短横线和下划线！${PLAIN}" >&2
            fi
        done
        local TAG
        if [ "$NON_INTERACTIVE" = 1 ] && jq -e --arg tag "$input_tag" '.inbounds[] | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null; then
            printf '[错误] 节点名称已存在：%s\n' "$input_tag" >&2; return 1
        fi
        TAG=$(get_unique_tag "$input_tag")
        if [ "$proto_idx" = 5 ]; then
            if [ -e "/etc/init.d/cloudflared-$TAG" ] || [ -L "/etc/init.d/cloudflared-$TAG" ] ||
               [ -e "/etc/systemd/system/cloudflared-$TAG.service" ] || [ -L "/etc/systemd/system/cloudflared-$TAG.service" ]; then
                echo '同名隧道服务已存在，请选择其他节点名称。' >&2
                if [ "$NON_INTERACTIVE" = 1 ]; then return 1; fi; continue
            fi
        fi

        case "$proto_idx" in
            2|3|4) if ! prompt_cert_type; then [ "$NON_INTERACTIVE" = 0 ] || return 1; continue; fi ;;
        esac
        backup_config || return 1
        local IS_ARGO=0
        local jq_ok=1

        case "$proto_idx" in
            1)
                local UUID
                UUID=$(get_uuid) || return 1
                local SNI
                resolve_reality_sni SNI || { restore_config_and_service || return 1; return 1; }
                local KEYS
                KEYS=$(/usr/local/lib/onebox/sing-box generate reality-keypair) || return 1
                local PK
                PK=$(echo "$KEYS" | grep PrivateKey | awk '{print $2}')
                local PUB
                PUB=$(echo "$KEYS" | grep PublicKey | awk '{print $2}')
                local SID
                SID=$(/usr/local/lib/onebox/sing-box generate rand --hex 4) || return 1
                [ -n "$PK" ] && [ -n "$PUB" ] && [ -n "$SID" ] || return 1
                save_secret "REALITY_PUB_${PORT}" "$PUB" || { restore_config_and_service || return 1; return 1; }

                apply_jq_config '.inbounds += [{"type":"vless","tag":$tag,"listen":"::","listen_port":$p,"users":[{"uuid":$uuid,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$pk,"short_id":[$sid]}}}]' \
                --argjson p "$PORT" --arg uuid "$UUID" --arg sni "$SNI" --arg pk "$PK" --arg sid "$SID" --arg tag "$TAG" || jq_ok=0
                ;;
            2)
                local PASS
                PASS=$(get_pass) || return 1
                apply_jq_config '.inbounds += [{"type":"hysteria2","tag":$tag,"listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"alpn":["h3"],"certificate_path":$cert,"key_path":$key}}]' \
                --argjson p "$PORT" --arg pass "$PASS" --arg tag "$TAG" --arg cert "$SEL_CERT" --arg key "$SEL_KEY" || jq_ok=0
                ;;
            3)
                local UUID
                UUID=$(get_uuid) || return 1
                local PASS
                PASS=$(get_pass) || return 1
                apply_jq_config '.inbounds += [{"type":"tuic","tag":$tag,"listen":"::","listen_port":$p,"users":[{"uuid":$uuid,"password":$pass}],"congestion_control":"bbr","tls":{"enabled":true,"alpn":["h3"],"certificate_path":$cert,"key_path":$key}}]' \
                --argjson p "$PORT" --arg uuid "$UUID" --arg pass "$PASS" --arg tag "$TAG" --arg cert "$SEL_CERT" --arg key "$SEL_KEY" || jq_ok=0
                ;;
            4)
                local PASS
                PASS=$(get_pass) || return 1
                apply_jq_config '.inbounds += [{"type":"anytls","tag":$tag,"listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"alpn":["h2","http/1.1"],"certificate_path":$cert,"key_path":$key}}]' \
                --argjson p "$PORT" --arg pass "$PASS" --arg tag "$TAG" --arg cert "$SEL_CERT" --arg key "$SEL_KEY" || jq_ok=0
                ;;
            5)
                IS_ARGO=1
                local UUID
                UUID=$(get_uuid) || return 1
                local ARGO_DOMAIN
                ARGO_DOMAIN=$(get_domain "请输入 Argo 隧道公共域名（需在 Cloudflare 配置）" "") || return 1
                local ARGO_IP
                ARGO_IP=$(get_domain "请输入 Argo 连接域名/IP（可选优选地址）" "$ARGO_DOMAIN" "true") || return 1

                local ARGO_TOKEN=""
                printf '%s\n' '需要安装连接器命令中的完整 Tunnel Token；隧道 ID 和 VLESS 用户 UUID 不能代替 Token。' >&2
                while true; do
                    ask "请输入完整 Cloudflare Tunnel Token（非隧道 ID）: " ARGO_TOKEN
                    if valid_tunnel_token "$ARGO_TOKEN"; then break; fi
                    echo '[错误] 不是有效的 Tunnel Token；请复制安装连接器命令中的 Token 本身，不要填 UUID、API Token 或整条命令。' >&2
                    if [ "$NON_INTERACTIVE" = 1 ]; then restore_config_and_service; return 1; fi
                done
                printf '[必须配置] Cloudflare 公共域名 %s → HTTP → http://127.0.0.1:%s；WebSocket 路径 /argo。脚本不创建云端映射。\n' "$ARGO_DOMAIN" "$PORT" >&2

                save_secret "ARGO_IP_${PORT}" "$ARGO_IP" || { restore_config_and_service || return 1; return 1; }
                save_secret "ARGO_DOMAIN_${PORT}" "$ARGO_DOMAIN" || { restore_config_and_service || return 1; return 1; }

                if ! apply_jq_config '.inbounds += [{"type":"vless","tag":$tag,"listen":"127.0.0.1","listen_port":$p,"users":[{"uuid":$uuid}],"transport":{"type":"ws","path":"/argo"}}]' \
                --argjson p "$PORT" --arg uuid "$UUID" --arg tag "$TAG"; then
                    jq_ok=0
                else
                    local CF_FAILED=0 CF_BIN CF_NEW=0
                    if [ -x /usr/local/lib/onebox/cloudflared ] && [ ! -L /usr/local/lib/onebox/cloudflared ]; then
                        CF_BIN=/usr/local/lib/onebox/cloudflared
                    else
                        CF_BIN=$(type -P cloudflared) || CF_BIN=""
                    fi
                    if [ -z "$CF_BIN" ] && { [ -e /usr/local/lib/onebox/cloudflared ] || [ -L /usr/local/lib/onebox/cloudflared ]; }; then
                        echo '[错误] cloudflared 目标路径异常，拒绝覆盖。' >&2
                        restore_config_and_service || return 1
                        return 1
                    fi
                    if [ -z "$CF_BIN" ]; then
                        CF_BIN=/usr/local/lib/onebox/cloudflared
                        echo -e "${CYAN}[信息] 正在下载 cloudflared 组件...${PLAIN}"
                        local TMP_CF
                        local cf_arch="$CF_ARCH"
                        [ -n "$cf_arch" ] || { echo "[错误] 此架构无 cloudflared 发布物。" >&2; restore_config_and_service; return 1; }
                        TMP_CF=$(mktemp) || { restore_config_and_service; return 1; }
                        SB_OWNED_TEMP_FILES+=("$TMP_CF")
                        if run_step "下载 cloudflared" fetch_url "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}" "$TMP_CF"; then
                            if ! chmod 755 "$TMP_CF" ||
                               ! chown 0:0 "$TMP_CF" ||
                               ! mv -n "$TMP_CF" /usr/local/lib/onebox/cloudflared; then
                                rm -f "$TMP_CF"
                                CF_FAILED=1
                            elif [ -e "$TMP_CF" ]; then
                                rm -f "$TMP_CF"
                                CF_FAILED=1
                            else
                                CF_NEW=1
                            fi
                        else
                            echo -e "${RED}[错误] 下载 cloudflared 失败！${PLAIN}"
                            rm -f "$TMP_CF"
                            CF_FAILED=1
                        fi
                    fi

                    if [[ ! "$CF_BIN" =~ ^/[A-Za-z0-9_./-]+$ ]] ||
                       [ ! -f "$CF_BIN" ] || [ ! -x "$CF_BIN" ]; then
                        echo 'cloudflared 路径无效，拒绝创建服务。' >&2
                        CF_FAILED=1
                    elif [ "$CF_FAILED" = 0 ] && ! "$CF_BIN" --version >/dev/null 2>&1; then
                        echo 'cloudflared 无法运行，拒绝创建服务。' >&2
                        CF_FAILED=1
                    fi
                    if [ "$CF_FAILED" = 0 ] && ! "$CF_BIN" tunnel run --help 2>&1 | grep -q -- '--token-file'; then
                        echo '[错误] cloudflared 不支持 --token-file；请升级到 2025.4.0 或更新版本后重试。' >&2
                        CF_FAILED=1
                    fi
                    if [ "$CF_FAILED" = 0 ] && [ "$CF_NEW" = 1 ]; then
                        if ! record_cloudflared_owner "$CF_BIN"; then
                            echo '[提示] 安装归属登记失败，组件将按非受管文件保留。' >&2
                            CF_FAILED=1
                        fi
                    fi
                    if [ "$CF_FAILED" = 0 ]; then
                        create_argo_service "$TAG" "$CF_BIN" "$ARGO_TOKEN" || CF_FAILED=1
                    fi
                    if [ "$CF_FAILED" -ne 0 ]; then
                        if [ "${CONFIG_TX_ARGO_PENDING:-}" = "$TAG" ] && ! cleanup_created_argo_service "$TAG"; then
                            echo '隧道清理失败，停止操作；请检查服务与事务备份。' >&2
                            return 1
                        fi
                        restore_config_and_service || return 1
                        echo '隧道创建失败，节点配置已恢复。' >&2
                        pause
                        if [ "$NON_INTERACTIVE" = 1 ]; then return 1; fi; continue
                    fi
                fi
                ;;
            6)
                local SS_METHOD
                SS_METHOD=$(get_ss_method) || return 1
                local SS_DEFAULT_PASS
                SS_DEFAULT_PASS=$(get_ss_password "$SS_METHOD") || return 1
                local PASS
                while true; do
                    ask "请输入SS密码 [默认按方法自动生成]: " PASS
                    PASS=${PASS:-$SS_DEFAULT_PASS}
                    if get_ss_pass_valid "$SS_METHOD" "$PASS"; then break; fi
                    echo -e "${RED}[错误] 错误：$SS_METHOD 要求 base64 密钥且长度精确(16/32字节)，请重新输入！${PLAIN}" >&2
                done
                apply_jq_config '.inbounds += [{"type":"shadowsocks","tag":$tag,"listen":"::","listen_port":$p,"method":$m,"password":$pass}]' \
                --argjson p "$PORT" --arg m "$SS_METHOD" --arg pass "$PASS" --arg tag "$TAG" || jq_ok=0
                ;;
        esac

        if [ "$jq_ok" -eq 0 ]; then
            restore_config_and_service || return 1
            pause
            if [ "$NON_INTERACTIVE" = 1 ]; then return 1; fi; continue
        fi

        if ! restart_service; then
            echo '节点启动失败，正在清理本次隧道并恢复配置。' >&2
            if [ "$IS_ARGO" -eq 1 ]; then
                cleanup_created_argo_service "$TAG" || {
                    echo '隧道清理失败，保留事务信息；请先处理残留服务。' >&2
                    return 1
                }
            fi
            restore_config_and_service || return 1
            pause
            if [ "$NON_INTERACTIVE" = 1 ]; then return 1; fi; continue
        fi

        commit_config || return 1

        if [ -n "$f_proto" ]; then
            echo ""
            ask "是否自动放行端口？(y/n) [默认: y]: " auto_fw
            if [[ "${auto_fw:-y}" == "y" || "${auto_fw:-y}" == "Y" ]]; then
                open_fw_port "$PORT" "$f_proto" || return 1
            fi
        fi

        print_config_detail "$TAG"
        if [ "$IS_ARGO" = 1 ]; then
            printf '[提示] 连接器已连上 Cloudflare；请确认 %s 的云端映射为 http://127.0.0.1:%s。\n' "$ARGO_DOMAIN" "$PORT"
        fi
        if [ "$NON_INTERACTIVE" = 1 ]; then return 0; fi
        pause
    done
}

modify_config() {
    while true; do
        ui_clear
        echo -e "选择: 更改节点\n"
        select_inbound || return

        while true; do
            ui_clear
            local TYPE
            TYPE=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .type' "$CONFIG_FILE")
            local OLD_PORT
            OLD_PORT=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .listen_port' "$CONFIG_FILE")

            if [ -z "$TYPE" ] || [ "$TYPE" == "null" ]; then
                break
            fi

            echo -e "\n当前选中: ${YELLOW}$TAG${PLAIN}"

            local action=""
            if [ "$TYPE" == "vless" ]; then
                local IS_REALITY
                IS_REALITY=$(jq -r --arg tag "$TAG" '[.inbounds[] | select(.tag==$tag) | .tls.reality.enabled] | .[0] // false' "$CONFIG_FILE" 2>/dev/null)
                [ "$IS_REALITY" == "true" ] && IS_REALITY=1 || IS_REALITY=0
                local IS_ARGO
                IS_ARGO=$(jq -r --arg tag "$TAG" '[.inbounds[] | select(.tag==$tag) | .transport.type] | .[0] // ""' "$CONFIG_FILE" 2>/dev/null)
                [ "$IS_ARGO" == "ws" ] && IS_ARGO=1 || IS_ARGO=0

                echo -e " 1) 更改 UUID"
                echo -e " 2) 更改端口"
                echo -e " 3) 更改节点名称"
                [ "$IS_REALITY" -eq 1 ] && echo -e " 4) 更改伪装域名"
                [ "$IS_ARGO" -eq 1 ] && echo -e " 4) 更改优选域名/IP"
                echo -e " 0) 返回\n"

                while true; do
                    local mod_idx
                    if [ "$IS_REALITY" -eq 1 ] || [ "$IS_ARGO" -eq 1 ]; then
                        ask "请选择 [0-4]: " mod_idx
                        case "$mod_idx" in
                            1) action="uuid"; break ;;
                            2) action="port"; break ;;
                            3) action="tag"; break ;;
                            4) [ "$IS_REALITY" -eq 1 ] && action="sni" || action="argo_ip"; break ;;
                            0) break ;;
                            *) echo -e "${RED}[错误] 错误!${PLAIN}" ;;
                        esac
                    else
                        ask "请选择 [0-3]: " mod_idx
                        case "$mod_idx" in
                            1) action="uuid"; break ;;
                            2) action="port"; break ;;
                            3) action="tag"; break ;;
                            0) break ;;
                            *) echo -e "${RED}[错误] 错误!${PLAIN}" ;;
                        esac
                    fi
                done
            elif [[ "$TYPE" == "hysteria2" || "$TYPE" == "anytls" || "$TYPE" == "tuic" || "$TYPE" == "shadowsocks" ]]; then
                echo -e " 1) 更改主密钥/密码"
                echo -e " 2) 更改端口"
                echo -e " 3) 更改节点名称"
                if [ "$TYPE" != "shadowsocks" ]; then echo -e " 4) 更改证书类型 (域名/自签)"; fi
                echo -e " 0) 返回\n"
                while true; do
                    if [ "$TYPE" == "shadowsocks" ]; then ask "请选择 [0-3]: " mod_idx; else ask "请选择 [0-4]: " mod_idx; fi
                    case "$mod_idx" in
                        1) action="pass"; break ;;
                        2) action="port"; break ;;
                        3) action="tag"; break ;;
                        4) if [ "$TYPE" != "shadowsocks" ]; then action="cert"; break; else echo -e "${RED}[错误] 错误!${PLAIN}"; fi ;;
                        0) break ;;
                        *) echo -e "${RED}[错误] 错误!${PLAIN}" ;;
                    esac
                done
            else
                echo -e "${RED}[错误] 不支持修改的协议类型${PLAIN}"
                pause
                break
            fi

            [ "$mod_idx" == "0" ] && break

            if [ "$action" == "argo_ip" ]; then
                local NEW_ARGO_IP argo_domain_key="ARGO_DOMAIN_${OLD_PORT}"
                NEW_ARGO_IP=$(get_domain "请输入新的 Argo 优选域名/IP" "${!argo_domain_key}" "true") || exit 1
                save_secret "ARGO_IP_${OLD_PORT}" "$NEW_ARGO_IP" || return 1
                echo -e "${GREEN}[完成] 优选域名/IP 已成功更改为: $NEW_ARGO_IP${PLAIN}"
                pause
                continue
            fi

            if [ "$action" = cert ]; then
                if ! prompt_cert_type; then
                    pause
                    continue
                fi
            fi
            backup_config || return 1

            if [ "$action" == "uuid" ] || [ "$action" == "pass" ]; then
                local NEW_AUTH
                if [ "$action" == "uuid" ]; then NEW_AUTH=$(get_uuid) || exit 1
                elif [ "$TYPE" == "shadowsocks" ]; then
                    local SS_METHOD_CUR
                    SS_METHOD_CUR=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .method // ""' "$CONFIG_FILE")
                    local SS_DEFAULT_PASS
                    SS_DEFAULT_PASS=$(get_ss_password "$SS_METHOD_CUR")
                    while true; do
                        ask "请输入新SS密码 [默认按方法自动生成]: " NEW_AUTH
                        NEW_AUTH=${NEW_AUTH:-$SS_DEFAULT_PASS}
                        if get_ss_pass_valid "$SS_METHOD_CUR" "$NEW_AUTH"; then break; fi
                        echo -e "${RED}[错误] 错误：$SS_METHOD_CUR 要求 base64 密钥且长度精确(16/32字节)，请重新输入！${PLAIN}" >&2
                    done
                else
                    NEW_AUTH=$(get_pass) || exit 1
                fi

                if [ "$action" == "uuid" ]; then
                    if ! apply_jq_config '(.inbounds[] | select(.tag==$tag) | .users[0].uuid) = $auth' --arg tag "$TAG" --arg auth "$NEW_AUTH"; then
                        restore_config_and_service || return 1
                        pause
                        continue
                    fi
                else
                    local PASS_FILTER='(.inbounds[] | select(.tag==$tag) | .users[0].password) = $auth'
                    if [ "$TYPE" == "shadowsocks" ]; then PASS_FILTER='(.inbounds[] | select(.tag==$tag) | .password) = $auth'; fi
                    if ! apply_jq_config "$PASS_FILTER" --arg tag "$TAG" --arg auth "$NEW_AUTH"; then
                        restore_config_and_service || return 1
                        pause
                        continue
                    fi
                fi

                if ! restart_service; then
                    echo -e "${RED}[错误] 操作失败，已还原配置！${PLAIN}"; restore_config_and_service || return 1
                else
                    echo -e "${GREEN}[完成] 节点秘钥已更新！${PLAIN}"; commit_config || return 1
                fi
                pause

            elif [ "$action" == "cert" ]; then
                if [ -s "$SEL_CERT" ] && [ -s "$SEL_KEY" ]; then
                    if ! apply_jq_config '(.inbounds[] | select(.tag==$tag) | .tls.certificate_path) = $cert | (.inbounds[] | select(.tag==$tag) | .tls.key_path) = $key' \
                    --arg tag "$TAG" --arg cert "$SEL_CERT" --arg key "$SEL_KEY"; then
                        restore_config_and_service || return 1
                        pause
                        continue
                    fi

                    if ! restart_service; then
                        echo -e "${RED}[错误] 操作失败，已还原配置！${PLAIN}"; restore_config_and_service || return 1
                    else
                        echo -e "${GREEN}[完成] 节点 $TAG 的证书已更新！${PLAIN}"; commit_config || return 1
                    fi
                else
                    restore_config_and_service || return 1
                fi
                pause

            elif [ "$action" == "port" ]; then
                local f_proto=""
                local check_proto="tcp"
                local IS_ARGO=0
                if [[ "$TYPE" == "vless" && "$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type // empty' "$CONFIG_FILE")" != "ws" ]]; then f_proto="tcp"; check_proto="tcp"
                elif [[ "$TYPE" == "vless" ]]; then f_proto=""; check_proto="tcp"; IS_ARGO=1
                elif [[ "$TYPE" == "hysteria2" || "$TYPE" == "tuic" ]]; then f_proto="udp"; check_proto="udp"
                elif [ "$TYPE" == "anytls" ]; then f_proto="tcp"; check_proto="tcp"
                elif [ "$TYPE" == "shadowsocks" ]; then f_proto="both"; check_proto="both"
                fi

                if [ "$IS_ARGO" -eq 1 ]; then
                    echo -e "\n${YELLOW}注意: 这是 Argo 节点，入口由 Cloudflare Tunnel 提供。${PLAIN}"
                    echo -e "${YELLOW}[提示] 改完本地端口后，必须去 Cloudflare Zero Trust 后台把该 Tunnel 的${PLAIN}"
                    echo -e "${YELLOW}[提示] Public Hostname (Ingress) 目标同步改成 http://127.0.0.1:<新端口>，${PLAIN}"
                    echo -e "${YELLOW}[提示] 否则节点会立即失效(隧道返回 502)。${PLAIN}"
                    ask "确认继续修改端口？(y/n) [默认: n]: " argo_go
                    if [[ "${argo_go:-n}" != "y" && "${argo_go:-n}" != "Y" ]]; then
                        commit_config || return 1
                        echo -e "${CYAN}[信息] 已取消。${PLAIN}"
                        pause
                        continue
                    fi
                fi

                local NEW_PORT
                while true; do
                    ask "请输入新端口 [默认随机]: " NEW_PORT
                    NEW_PORT=${NEW_PORT:-$(rand_port)}
                    if ! [[ "$NEW_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then echo -e "${RED}[错误] 错误输入!${PLAIN}"; continue; fi
                    if [ "$NEW_PORT" != "$OLD_PORT" ] && check_port "$NEW_PORT" "$check_proto" "$TAG"; then echo -e "${RED}[错误] 端口占用!${PLAIN}"; continue; fi
                    break
                done
                warn_port_shared "$NEW_PORT" "$check_proto" "$TAG"

                if ! apply_jq_config '(.inbounds[] | select(.tag==$tag) | .listen_port) = $p' --arg tag "$TAG" --argjson p "$NEW_PORT"; then
                    restore_config_and_service || return 1
                    pause
                    continue
                fi

                load_secrets
                local IS_REALITY_NODE
                IS_REALITY_NODE=$(jq -r --arg tag "$TAG" '[.inbounds[] | select(.tag==$tag) | .tls.reality.enabled] | .[0] // false' "$CONFIG_FILE" 2>/dev/null)
                [ "$IS_REALITY_NODE" == "true" ] && IS_REALITY_NODE=1 || IS_REALITY_NODE=0
                if [ "$(jq -r --arg tag "$TAG" '[.inbounds[] | select(.tag==$tag) | .transport.type] | .[0] // ""' "$CONFIG_FILE" 2>/dev/null)" == "ws" ]; then
                    IS_ARGO=1
                fi
                if [ "$IS_REALITY_NODE" -eq 1 ]; then
                    local var_pub="REALITY_PUB_${OLD_PORT}"
                    local PUB="${!var_pub}"
                    if [ -n "$PUB" ]; then
                        save_secret "REALITY_PUB_${NEW_PORT}" "$PUB" || { restore_config_and_service || return 1; return 1; }
                    fi
                fi
                if [ "$IS_ARGO" -eq 1 ]; then
                    local var_ip="ARGO_IP_${OLD_PORT}"
                    local var_dom="ARGO_DOMAIN_${OLD_PORT}"
                    local A_IP="${!var_ip}"
                    local A_DOM="${!var_dom}"
                    if [ -n "$A_IP" ]; then
                        save_secret "ARGO_IP_${NEW_PORT}" "$A_IP" || { restore_config_and_service || return 1; return 1; }
                    fi
                    if [ -n "$A_DOM" ]; then
                        save_secret "ARGO_DOMAIN_${NEW_PORT}" "$A_DOM" || { restore_config_and_service || return 1; return 1; }
                    fi
                fi

                local SEC_TYPE=""
                [ "$IS_REALITY_NODE" -eq 1 ] && SEC_TYPE="vless"
                if [ "$OLD_PORT" != "$NEW_PORT" ]; then
                    cleanup_node_secrets "$OLD_PORT" "$SEC_TYPE" "$IS_ARGO" || { restore_config_and_service || return 1; return 1; }
                fi
                if ! restart_service; then
                    echo -e "${RED}[错误] 操作失败，已还原配置！${PLAIN}"
                    restore_config_and_service || return 1
                else
                    commit_config || return 1

                    echo -e "${GREEN}[完成] 端口已更改为: $NEW_PORT${PLAIN}"

                    if [ -n "$f_proto" ] && [ "$OLD_PORT" != "$NEW_PORT" ]; then
                        if close_fw_port "$OLD_PORT" "$f_proto"; then
                            remove_fw_record "${OLD_PORT}" "$f_proto" || return 1
                        else
                            echo '旧端口规则清理未完成，记录已保留。' >&2
                        fi
                        ask "是否自动放行新端口？(y/n) [默认: y]: " auto_fw
                        if [[ "${auto_fw:-y}" == "y" || "${auto_fw:-y}" == "Y" ]]; then open_fw_port "$NEW_PORT" "$f_proto"; fi
                    fi

                    if [ "$IS_ARGO" -eq 1 ]; then
                        echo -e "\n${YELLOW}【重要警告】: 您修改了 Argo 节点的本地端口！\n请务必前往 Cloudflare Zero Trust 后台，将对应 Tunnel 的 Public Hostname (Ingress) 映射目标同步更改为 http://127.0.0.1:${NEW_PORT}，否则节点将无法连接！${PLAIN}\n"
                    fi
                fi
                pause

            elif [ "$action" == "tag" ]; then
                local NEW_TAG=""
                while true; do
                    ask "请输入新的节点名称: " NEW_TAG
                    NEW_TAG=${NEW_TAG// /-}
                    if [ -z "$NEW_TAG" ]; then echo -e "${RED}[错误] 不能为空!${PLAIN}"; continue; fi
                    if ! [[ "$NEW_TAG" =~ ^[a-zA-Z0-9_-]+$ ]]; then echo -e "${RED}[错误] 错误：节点名称仅限字母、数字、短横线和下划线！${PLAIN}"; continue; fi
                    if jq -e --arg tag "$NEW_TAG" '.inbounds[] | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then echo -e "${RED}[错误] 名称已存在！${PLAIN}"; continue; fi
                    break
                done

                local IS_ARGO
                IS_ARGO=$(jq -r --arg tag "$TAG" '[.inbounds[] | select(.tag==$tag) | .transport.type] | .[0] // ""' "$CONFIG_FILE" 2>/dev/null)
                [ "$IS_ARGO" == "ws" ] && IS_ARGO=1 || IS_ARGO=0

                if ! apply_jq_config '(.inbounds[] | select(.tag==$tag) | .tag) = $newtag' --arg tag "$TAG" --arg newtag "$NEW_TAG"; then
                    restore_config_and_service || return 1
                    pause
                    continue
                fi

                if ! restart_service; then
                    echo -e "${RED}[错误] 操作失败，已还原配置！${PLAIN}"
                    restore_config_and_service || return 1
                else
                    if [ "$IS_ARGO" -eq 1 ]; then
                        if ! rename_argo_service "$TAG" "$NEW_TAG"; then
                            restore_config_and_service || return 1
                            printf '%s\n' 'Argo 服务重命名失败，节点名称已恢复。' >&2
                            return 1
                        fi
                    fi
                    echo -e "${GREEN}[完成] 节点名称已成功更改为: $NEW_TAG${PLAIN}"
                    commit_config || return 1
                    TAG="$NEW_TAG"
                fi
                pause

            elif [ "$action" == "sni" ]; then
                local NEW_SNI
                resolve_reality_sni NEW_SNI || { restore_config_and_service || return 1; return 1; }

                if ! apply_jq_config '(.inbounds[] | select(.tag==$tag) | .tls.server_name) = $sni | (.inbounds[] | select(.tag==$tag) | .tls.reality.handshake.server) = $sni' \
                --arg tag "$TAG" --arg sni "$NEW_SNI"; then
                    restore_config_and_service || return 1
                    pause
                    continue
                fi

                if ! restart_service; then
                    echo -e "${RED}[错误] 操作失败，已还原配置！${PLAIN}"
                    restore_config_and_service || return 1
                else
                    echo -e "${GREEN}[完成] 伪装域名已成功更改为: $NEW_SNI${PLAIN}"
                    commit_config || return 1
                fi
                pause
            fi
        done
    done
}

del_config() {
    while true; do
        ui_clear
        echo -e "选择: 删除节点\n"
        select_inbound || return 1

        local TYPE
        TYPE=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .type' "$CONFIG_FILE")
        local PORT
        PORT=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .listen_port' "$CONFIG_FILE")
        local IS_ARGO
        IS_ARGO=$(jq -r --arg tag "$TAG" '[.inbounds[] | select(.tag==$tag) | .transport.type] | .[0] // ""' "$CONFIG_FILE" 2>/dev/null)
        [ "$IS_ARGO" == "ws" ] && IS_ARGO=1 || IS_ARGO=0

        backup_config || return 1

        if [ "$IS_ARGO" = 1 ] && ! backup_argo_service_for_delete "$TAG"; then
            printf '[错误] 无法完整备份隧道服务及 Token，已取消删除。\n' >&2
            restore_config_and_service || return 1
            return 1
        fi

        if ! apply_jq_config 'del(.inbounds[] | select(.tag == $tag))' --arg tag "$TAG"; then
            restore_config_and_service || return 1
            pause
            [ "$NON_INTERACTIVE" = 0 ] || return 1
            continue
        fi

        if ! cleanup_node_secrets "$PORT" "$TYPE" "$IS_ARGO"; then
            restore_config_and_service || return 1
            return 1
        fi
        if ! restart_service; then
            echo -e "${RED}[错误] 删除失败：配置还原，内核未能正常重启！${PLAIN}"
            restore_config_and_service || return 1
            pause
            [ "$NON_INTERACTIVE" = 0 ] || return 1
            continue
        fi

        if [ "$IS_ARGO" = 1 ]; then
            if ! cleanup_created_argo_service_impl "$TAG" || ! unregister_argo_service "cloudflared-$TAG"; then
                printf '[错误] 隧道删除未完成，正在恢复节点、服务与 Token。\n' >&2
                if ! restore_config_and_service; then
                    CONFIG_TX_BLOCKED=1
                    printf '[错误] 隧道恢复失败，完整备份保留在 %s。\n' "$CONFIG_TX_DIR" >&2
                fi
                return 1
            fi
        fi
        commit_config || return 1

        local f_proto=""
        if [[ "$TYPE" == "vless" && "$IS_ARGO" -eq 0 ]]; then f_proto="tcp"
        elif [[ "$TYPE" == "hysteria2" || "$TYPE" == "tuic" ]]; then f_proto="udp"
        elif [ "$TYPE" == "anytls" ]; then f_proto="tcp"
        elif [ "$TYPE" == "shadowsocks" ]; then f_proto="both"
        fi

        if [ -n "$f_proto" ]; then
            if close_fw_port "$PORT" "$f_proto"; then
                remove_fw_record "${PORT}" "$f_proto" || return 1
            else
                echo '节点已删除，但防火墙规则及记录保留，请手动核查。' >&2
                [ "$NON_INTERACTIVE" = 0 ] || return 1
            fi
        fi

        local INBOUND_COUNT
        INBOUND_COUNT=$(jq '.inbounds | length' "$CONFIG_FILE")
        if [ "$INBOUND_COUNT" -eq 0 ]; then
            echo -e "${GREEN}[完成] 配置 $TAG 已删除！检测到已无节点，内核已自动停止。${PLAIN}"
        else
            echo -e "${GREEN}[完成] 配置 $TAG 已删除！${PLAIN}"
        fi
        [ "$NON_INTERACTIVE" = 0 ] || return 0
        pause
    done
}

view_single_config() {
    while true; do
        ui_clear
        echo -e "选择: 单协议链接\n"
        require_config readonly || { pause; return 1; }
        select_inbound || return
        print_config_detail "$TAG"
        pause
    done
}

nodes_need_public_ip() {
    jq -e --arg tag "${1:-}" 'any(.inbounds[];
      .tag != null and .tag != "dns-in" and
      ($tag == "" or .tag == $tag) and .transport.type != "ws" and
      ((.tls.certificate_path // "") | endswith("/real.cer") | not))' "$CONFIG_FILE" >/dev/null
}

show_all_links() {
    ui_clear
    echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo -e "🚀【 聚合节点 】节点信息如下：\n"
    require_config readonly || { pause; return 1; }

    local old_IFS=$IFS
    IFS=$'\n'
    read_all_tags || return 1
    IFS=$old_IFS

    if [ ${#TAGS[@]} -eq 0 ]; then
        echo -e "${RED}[错误] 未添加节点配置！${PLAIN}"
    else
        IP=""
        IP_LOOKUP_SKIPPED=0
        if nodes_need_public_ip; then get_ip || :; IP=$GLOBAL_IP; fi
        if [ "$IP_LOOKUP_SKIPPED" = 1 ]; then
            printf '[提示] 进程额度不足，已跳过分享链接生成；稍后重试，或用 onebox links --address 指定地址。\n'
        else
            for TAG in "${TAGS[@]}"; do
                build_share_url "$TAG" "$IP"
                printf '\n'
            done
        fi
    fi
    echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    pause
}

view_config() {
    while true; do
        ui_clear
        echo -e "选择: 查看节点\n"
        echo -e " 1) 单协议链接"
        echo -e " 2) 聚合链接"
        echo -e " 0) 返回\n"
        while true; do
            local v_idx
            ask "请选择 [0-2]: " v_idx
            case "$v_idx" in 1) view_single_config; break ;; 2) show_all_links; break ;; 0) return ;; *) echo -e "${RED}[错误] 输入错误!${PLAIN}" ;; esac
        done
    done
}

run_manage() {
    local run_idx=""
    while true; do
        ui_clear
        echo -e "选择: 运行管理\n"
        echo -e " 1) 启动"
        echo -e " 2) 停止"
        echo -e " 3) 重启"
        echo -e " 4) 只读体检"
        echo -e " 5) 查看最近服务日志"
        echo -e " 0) 返回\n"
        while true; do
            ask "请选择 [0-5]: " run_idx
            case "$run_idx" in
                1|3)
                   if [ "$run_idx" = 1 ] && service_is_active; then
                       echo -e "${GREEN}[完成] 服务已运行，无需重复启动。${PLAIN}"
                       pause; break
                   fi
                   local INBOUND_COUNT
                   INBOUND_COUNT=$(jq '.inbounds | length' "$CONFIG_FILE" 2>/dev/null)
                   if [ -z "$INBOUND_COUNT" ] || [ "$INBOUND_COUNT" -eq 0 ]; then echo -e "${RED}[错误] 未添加节点配置！${PLAIN}"; pause; break; fi
                   if ! restart_service; then
                       echo -e "${RED}[错误] 操作失败！内核启动失败，请检查配置。${PLAIN}"
                   else
                       echo -e "${GREEN}[完成] 已启动${PLAIN}"
                   fi
                   pause; break ;;
                2)
                   local stop_rc=0
                   if [ "$SERVICE_MANAGER" == openrc ]; then rc-service onebox stop || stop_rc=$?; else systemctl stop onebox || stop_rc=$?; fi
                   if [ "$stop_rc" = 0 ]; then
                       echo -e "${GREEN}[完成] 已停止${PLAIN}"
                   else
                       printf '%s\n' '停止服务失败，请检查服务状态。' >&2
                   fi
                   pause; break ;;
                4) cli_doctor; pause; break ;;
                5) CLI_LOG_SOURCE=service CLI_LINES=80 CLI_TAG="" cli_logs; pause; break ;;
                0) return ;;
                *) echo -e "${RED}[错误] 输入错误!${PLAIN}" ;;
            esac
        done
    done
}

update_manage() {
    while true; do
        ui_clear
        echo -e "${CYAN}[信息] 正在检查更新，请稍候...${PLAIN}"
        local CUR_VER="未安装"
        if kernel_ok; then
            local extracted_ver
            extracted_ver=$( ( /usr/local/lib/onebox/sing-box version ) 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
            [ -n "$extracted_ver" ] && CUR_VER="$extracted_ver"
        fi
        local NEW_VER
        NEW_VER=$(get_latest_version)
        local SB_UPDATE_TEXT="更新 sing-box 内核"
        if kernel_ok && [ -n "$NEW_VER" ]; then
            if [ "$CUR_VER" != "$NEW_VER" ]; then SB_UPDATE_TEXT="更新 sing-box 内核 ${GREEN}[发现新版: v${NEW_VER}]${PLAIN}"
            else SB_UPDATE_TEXT="更新 sing-box 内核 ${YELLOW}[已是最新: v${CUR_VER}]${PLAIN}"
            fi
        fi

        ui_clear
        echo -e "选择: 更新\n"
        echo -e " 1) ${SB_UPDATE_TEXT}"
        echo -e " 2) 更新脚本"
        echo -e " 3) 强制覆盖重装内核"
        echo -e " 0) 返回\n"
        local up_idx
        while true; do
            ask "请选择 [0-3]: " up_idx
            case "$up_idx" in
                1)
                    if [ -z "$NEW_VER" ]; then echo -e "${RED}[错误] 获取最新版本失败！API 受限或网络超时。${PLAIN}"; pause; break; fi
                    if kernel_ok && [ "$CUR_VER" == "$NEW_VER" ]; then echo -e "\n${GREEN}当前已是最新，无需更新！${PLAIN}"; pause; break; fi

                    echo -e "\n${YELLOW}即将更新内核至 v${NEW_VER}...${PLAIN}"
                    install_kernel "$NEW_VER" restart
                    pause; break ;;
                2)
                    echo -e "\n${CYAN}正在拉取最新脚本代码...${PLAIN}"
                    if fetch_script; then
                        echo -e "${GREEN}[完成] 脚本代码更新成功！请重新运行 onebox 命令。${PLAIN}"
                        exit 0
                    else
                        echo -e "${RED}[错误] 下载脚本失败或内容校验不通过！更新中止。${PLAIN}"
                        pause; break
                    fi
                    ;;
                3)
                    if [ -z "$NEW_VER" ]; then
                        ask "获取最新版本失败，请手动输入要安装的版本号 (如 1.10.1): " NEW_VER
                        [ -z "$NEW_VER" ] && { echo -e "${RED}[错误] 未输入版本号，已取消。${PLAIN}"; pause; break; }
                    fi
                    if ! [[ "$NEW_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        echo -e "${RED}[错误] 版本号格式错误(应为 x.y.z)，已取消。${PLAIN}"
                        pause; break
                    fi
                    echo -e "\n${YELLOW}将强制覆盖安装 v${NEW_VER}（无论当前版本是否相同）。${PLAIN}"
                    ask "确认继续？(y/n) [默认: y]: " fc
                    if [[ "${fc:-y}" == "y" || "${fc:-y}" == "Y" ]]; then
                        install_kernel "$NEW_VER" restart
                    else
                        echo -e "${YELLOW}[提示] 已取消。${PLAIN}"
                    fi
                    pause; break ;;
                0) return ;;
                *) echo -e "${RED}[错误] 输入错误!${PLAIN}" ;;
            esac
        done
    done
}

BBR_STATE_DIR="/var/lib/onebox/bbr"
BBR_SYSCTL_FILE="/etc/sysctl.d/90-onebox-bbr.conf"
CLOUDFLARED_OWNER_FILE="/var/lib/onebox/cloudflared-owner"
bbr_state_valid() {
    local cc qdisc
    [ -f "$BBR_STATE_DIR/original" ] && [ ! -L "$BBR_STATE_DIR/original" ] || return 1
    [ -f "$BBR_STATE_DIR/managed.conf" ] || return 1
    { IFS= read -r cc && IFS= read -r qdisc; } < "$BBR_STATE_DIR/original" || return 1
    [[ "$cc" =~ ^[a-zA-Z0-9_-]+$ && "$qdisc" =~ ^[a-zA-Z0-9_-]+$ ]]
}

bbr_rollback_runtime() {
    local cc="$1" qdisc="$2" actual_cc actual_qdisc failed=0
    sysctl -q -w "net.ipv4.tcp_congestion_control=$cc" || failed=1
    sysctl -q -w "net.core.default_qdisc=$qdisc" || failed=1
    actual_cc=$(sysctl -n net.ipv4.tcp_congestion_control) || failed=1
    actual_qdisc=$(sysctl -n net.core.default_qdisc) || failed=1
    if [ "$actual_cc" != "$cc" ] || [ "$actual_qdisc" != "$qdisc" ]; then failed=1; fi
    if [ "$failed" = 0 ]; then
        printf '[提示] 恢复失败，已撤回本次运行参数修改。\n' >&2
    else
        printf '[错误] 撤回未完成；当前算法=%s，队列=%s；备份=%s\n' "$actual_cc" "$actual_qdisc" "$BBR_STATE_DIR" >&2
    fi
    return "$failed"
}

bbr_check_conflicts() {
    local f dir rc
    local pattern='^[[:space:]]*-?[[:space:]]*net[./](core[./]default_qdisc|ipv4[./]tcp_congestion_control)[[:space:]]*='
    local -a files=(/etc/sysctl.conf)
    local -a found=()
    for dir in /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d; do
        for f in "$dir"/*.conf; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            [ "$f" = "$BBR_SYSCTL_FILE" ] && continue
            files+=("$f")
        done
    done
    for f in "${files[@]}"; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        grep -nE "$pattern" "$f" >/dev/null 2>&1
        rc=$?
        if [ "$rc" = 0 ]; then
            printf '[提示] 检测到外部网络配置：%s\n' "$f" >&2
            found+=("$f")
        elif [ "$rc" != 1 ]; then
            printf '[错误] 无法检查网络配置：%s\n' "$f" >&2
            return 1
        fi
    done
    if [ "${#found[@]}" -gt 0 ]; then
        printf '[错误] 请先手动处理上述 sysctl 冲突，再启用 BBR；外部配置未修改。\n' >&2
        return 1
    fi
    return 0
}

restore_managed_bbr() {
    local cc qdisc old_cc old_qdisc failed=0
    bbr_state_valid || return 1
    [ ! -L "$BBR_SYSCTL_FILE" ] || return 1
    if [ -e "$BBR_SYSCTL_FILE" ] &&
       ! cmp -s "$BBR_STATE_DIR/managed.conf" "$BBR_SYSCTL_FILE"; then return 1; fi
    { IFS= read -r cc && IFS= read -r qdisc; } < "$BBR_STATE_DIR/original" || return 1
    old_cc=$(sysctl -n net.ipv4.tcp_congestion_control) || return 1
    old_qdisc=$(sysctl -n net.core.default_qdisc) || return 1
    sysctl -q -w "net.core.default_qdisc=$qdisc" || failed=1
    if [ "$failed" = 0 ]; then
        sysctl -q -w "net.ipv4.tcp_congestion_control=$cc" || failed=1
    fi
    [ "$(sysctl -n net.core.default_qdisc)" = "$qdisc" ] || failed=1
    [ "$(sysctl -n net.ipv4.tcp_congestion_control)" = "$cc" ] || failed=1
    if [ "$failed" != 0 ]; then
        bbr_rollback_runtime "$old_cc" "$old_qdisc" || :
        return 1
    fi
    if ! rm -f -- "$BBR_SYSCTL_FILE"; then
        bbr_rollback_runtime "$old_cc" "$old_qdisc" || :
        return 1
    fi
    rm -rf -- "$BBR_STATE_DIR" || return 1
    return 0
}
offer_bbr_restore() {
    local reply cc qdisc
    if [ ! -d "$BBR_STATE_DIR" ]; then
        if [ -e /etc/sysctl.d/99-bbr.conf ] || [ -f "$CONFIG_DIR/.sysctl_backup" ]; then
            printf '[提示] 无 BBR+FQ 修改记录，保持当前设置。\n'
        fi
        return 0
    fi
    if ! bbr_state_valid; then
        printf '[错误] BBR 恢复记录不完整，保留设置和记录：%s\n' "$BBR_STATE_DIR" >&2
        [ "${CLI_RESTORE_BBR:-1}" = 0 ] && return 0
        return 1
    fi
    { IFS= read -r cc && IFS= read -r qdisc; } < "$BBR_STATE_DIR/original" || return 1
    printf '[信息] 修改前：拥塞控制=%s，队列=%s。\n' "$cc" "$qdisc"
    ask "是否恢复修改前的网络算法和队列？[y/N]: " reply
    case "$reply" in
        y|Y)
            if restore_managed_bbr; then
                printf '[完成] 已恢复原网络算法和队列。\n'
            else
                printf '[错误] 恢复未完成或配置已被修改；卸载暂停，恢复记录保留：%s\n' "$BBR_STATE_DIR" >&2
                return 1
            fi ;;
        *) printf '[提示] 保留 BBR+FQ，备份：%s\n' "$BBR_STATE_DIR" ;;
    esac
}

enable_bbr() {
    local cc qdisc stage
    cc=$(sysctl -n net.ipv4.tcp_congestion_control) || return 1
    qdisc=$(sysctl -n net.core.default_qdisc) || return 1
    printf '[信息] 当前算法：%s；默认队列：%s。\n' "$cc" "$qdisc"
    bbr_check_conflicts || { pause; return 1; }
    if [ -e "$BBR_STATE_DIR" ] || [ -L "$BBR_STATE_DIR" ]; then
        if ! bbr_state_valid || [ -L "$BBR_SYSCTL_FILE" ]; then
            printf '[提示] BBR+FQ 恢复记录无效，请先检查；未覆盖。\n'
            pause
            return 1
        fi
        if [ -e "$BBR_SYSCTL_FILE" ] &&
           ! cmp -s "$BBR_STATE_DIR/managed.conf" "$BBR_SYSCTL_FILE"; then
            printf '[提示] BBR+FQ 配置已被外部修改，请先检查；未覆盖。\n'
            pause
            return 1
        fi
        if [ ! -e "$BBR_SYSCTL_FILE" ]; then
            local rebuild
            ask "BBR+FQ 配置缺失，是否按有效记录重建？[y/N]: " rebuild
            case "$rebuild" in y|Y) ;; *) pause; return 0 ;; esac
            if ! (set -C; cat "$BBR_STATE_DIR/managed.conf" > "$BBR_SYSCTL_FILE") || ! chmod 644 "$BBR_SYSCTL_FILE"; then
                printf '[错误] 无法重建 BBR+FQ 持久化配置。\n' >&2
                pause
                return 1
            fi
        fi
        if [ "$cc" = bbr ] && [ "$qdisc" = fq ]; then
            printf '[完成] BBR+FQ 已生效，本脚本的持久化配置存在。\n'
            pause
            return 0
        fi
        if run_step "重新应用 BBR+FQ" sysctl -p "$BBR_SYSCTL_FILE" &&
           [ "$(sysctl -n net.ipv4.tcp_congestion_control)" = bbr ] &&
           [ "$(sysctl -n net.core.default_qdisc)" = fq ]; then
            printf '[完成] BBR+FQ 已重新应用，原始备份保持不变。\n'
            pause
            return 0
        fi
        printf '[错误] BBR+FQ 未完全生效，配置及恢复记录已保留。\n' >&2
        pause
        return 1
    fi
    if [ -e "$BBR_SYSCTL_FILE" ] || [ -L "$BBR_SYSCTL_FILE" ]; then
        printf '[提示] 存在非本脚本登记的 BBR 配置，未覆盖。\n'
        pause
        return 1
    fi
    [[ "$cc" =~ ^[a-zA-Z0-9_-]+$ && "$qdisc" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    mkdir -p /var/lib/onebox /etc/sysctl.d || return 1
    chmod 755 /etc/sysctl.d 2>/dev/null || :
    stage=$(mktemp -d /var/lib/onebox/.bbr.XXXXXX) || return 1
    if ! printf '%s\n' "$cc" "$qdisc" > "$stage/original" ||
       ! printf '%s\n' 'net.core.default_qdisc=fq' 'net.ipv4.tcp_congestion_control=bbr' > "$stage/managed.conf"; then
        rm -rf -- "$stage"
        return 1
    fi
    if ! mv -n "$stage" "$BBR_STATE_DIR" || [ -d "$stage" ]; then
        rm -rf -- "$stage"
        return 1
    fi
    if ! (set -C; cat "$BBR_STATE_DIR/managed.conf" > "$BBR_SYSCTL_FILE") || ! chmod 644 "$BBR_SYSCTL_FILE"; then
        printf '[错误] BBR 配置创建失败；保留恢复记录，请检查。\n' >&2
        return 1
    fi
    modprobe tcp_bbr 2>/dev/null || :
    if run_step "应用 BBR+FQ" sysctl -p "$BBR_SYSCTL_FILE" &&
       [ "$(sysctl -n net.ipv4.tcp_congestion_control)" = bbr ] &&
       [ "$(sysctl -n net.core.default_qdisc)" = fq ]; then
        printf '[完成] BBR+FQ 已开启，原配置已备份。\n'
    else
        if restore_managed_bbr; then
            printf '[错误] 开启失败，已恢复修改前参数。\n' >&2
        else
            printf '[错误] 开启或恢复失败，保留记录：%s\n' "$BBR_STATE_DIR" >&2
        fi
        pause
        return 1
    fi
    pause
}

config_outbound() {
    local out_idx=""
    while true; do
        ui_clear
        local current_strategy
        current_strategy=$(jq -r '.outbounds[] | select(.tag=="direct") | ((if (.domain_resolver | type) == "object" then .domain_resolver.strategy else null end) // .domain_strategy // "auto")' "$CONFIG_FILE" 2>/dev/null)
        echo -e "选择: 配置出站 IPv4/IPv6 策略"
        echo -e "当前出站策略: ${GREEN}${current_strategy}${PLAIN}\n"
        echo -e " 1) 仅 IPv4 出站 (ipv4_only)"
        echo -e " 2) 仅 IPv6 出站 (ipv6_only)"
        echo -e " 3) 自动/双栈出站 (auto)"
        echo -e " 0) 返回\n"
        ask "请选择 [0-3]: " out_idx

        local USE_NEW_FORMAT=0
        if ! kernel_ok || sb_ge_112; then
            USE_NEW_FORMAT=1
        fi

        local strategy=""
        case "$out_idx" in
            1) strategy="ipv4_only" ;;
            2) strategy="ipv6_only" ;;
            3) strategy="auto" ;;
            0) return ;;
            *) echo -e "${RED}[错误] 输入错误!${PLAIN}"; sleep 1; continue ;;
        esac

        local jq_success=0
        backup_config || return 1
        if [ "$strategy" == "auto" ]; then
            apply_jq_config '(.outbounds[] | select(.tag=="direct")) |= del(.domain_strategy, .domain_resolver)' && jq_success=1
        elif [ "$USE_NEW_FORMAT" -eq 1 ]; then
            apply_jq_config "
              $JQ_DNS_LOCAL |
              (.outbounds[] | select(.tag==\"direct\")) |= (del(.domain_strategy) | .domain_resolver = {\"server\": \"dns-local\", \"strategy\": \$s})
            " --arg s "$strategy" && jq_success=1
        else
            apply_jq_config '(.outbounds[] | select(.tag=="direct")).domain_strategy = $s' --arg s "$strategy" && jq_success=1
        fi

        if [ "$jq_success" -eq 0 ]; then
            restore_config_and_service || return 1
            pause
            continue
        fi

        if ! restart_service; then
            echo -e "${RED}[错误] 操作失败(校验报错)，配置已还原！${PLAIN}"
            restore_config_and_service || return 1
        else
            echo -e "${GREEN}[完成] 出站策略已更新！${PLAIN}"
            commit_config || return 1
        fi
        pause
    done
}

other_manage() {
    local om_idx=""
    while true; do
        ui_clear
        echo -e "选择: 其他\n"
        echo -e " 1) 开启 BBR+FQ"
        echo -e " 2) 配置出站 IPv4/IPv6"
        echo -e " 0) 返回\n"
        ask "请选择 [0-2]: " om_idx
        case "$om_idx" in
            1) enable_bbr ;;
            2) config_outbound ;;
            0) return ;;
            *) echo -e "${RED}[错误] 输入错误!${PLAIN}"; sleep 1 ;;
        esac
    done
}

stop_managed_service() {
    local svc="$1" state
    [[ "$svc" == onebox || "$svc" =~ ^cloudflared-[A-Za-z0-9_-]+$ ]] || return 1
    if [ "$SERVICE_MANAGER" = openrc ]; then
        if [ ! -e "/etc/init.d/$svc" ]; then
            [ ! -e "/etc/runlevels/default/$svc" ] && [ ! -L "/etc/runlevels/default/$svc" ]
            return $?
        fi
        local rc
        rc-service "$svc" status >/dev/null 2>&1; rc=$?
        case "$rc" in
            0) rc-service "$svc" stop || return 1 ;;
            3) ;;
            *) printf '[错误] 无法确认 %s 状态（%s），未删除服务。\n' "$svc" "$rc" >&2; return 1 ;;
        esac
        rc-service "$svc" status >/dev/null 2>&1; rc=$?
        [ "$rc" = 3 ] || { printf '[错误] 未确认 %s 已停止。\n' "$svc" >&2; return 1; }
        if [ -e "/etc/runlevels/default/$svc" ] || [ -L "/etc/runlevels/default/$svc" ]; then
            rc-update del "$svc" default || return 1
        fi
    else
        state=$(systemctl show "$svc" -p LoadState --value) || return 1
        case "$state" in
            not-found) return 0 ;;
            loaded|masked) ;;
            *) printf '无法确认服务 %s 状态：%s\n' "$svc" "$state" >&2; return 1 ;;
        esac
        systemctl stop "$svc" || return 1
        state=$(systemctl show "$svc" -p ActiveState --value) || return 1
        case "$state" in inactive|failed) ;; *) return 1 ;; esac
        systemctl disable "$svc" >/dev/null 2>&1 || return 1
    fi
    return 0
}

record_cloudflared_owner() {
    local bin="$1" sum tmp
    [ "$bin" = /usr/local/lib/onebox/cloudflared ] && [ -f "$bin" ] && [ ! -L "$bin" ] || return 1
    sum=$(sha256sum "$bin") || return 1
    sum=${sum%% *}
    mkdir -p "$(dirname "$CLOUDFLARED_OWNER_FILE")" || return 1
    tmp=$(mktemp "$CLOUDFLARED_OWNER_FILE.XXXXXX") || return 1
    if printf '%s\n' 'onebox-manager-v1' "$bin" "$sum" > "$tmp" &&
       chmod 600 "$tmp" && mv -f "$tmp" "$CLOUDFLARED_OWNER_FILE"; then return 0; fi
    rm -f "$tmp"
    return 1
}
cloudflared_owner_valid() {
    local record="$CLOUDFLARED_OWNER_FILE" sum legacy=0
    local -a fields=()
    if [ ! -e "$record" ] && [ ! -L "$record" ]; then
        record="$CONFIG_DIR/.cloudflared-owner"
        legacy=1
    fi
    [ -f "$record" ] && [ ! -L "$record" ] || return 1
    mapfile -t fields < "$record" || return 1
    [ "${#fields[@]}" = 3 ] || return 1
    [ "${fields[0]}" = onebox-manager-v1 ] || return 1
    [ "${fields[1]}" = /usr/local/lib/onebox/cloudflared ] || return 1
    [[ "${fields[2]}" =~ ^[a-f0-9]{64}$ ]] || return 1
    [ -f "${fields[1]}" ] && [ ! -L "${fields[1]}" ] || return 1
    sum=$(sha256sum "${fields[1]}") || return 1
    [ "${sum%% *}" = "${fields[2]}" ] || return 1
    if [ "$legacy" = 1 ]; then
        record_cloudflared_owner "${fields[1]}" || {
            echo '[错误] cloudflared 归属迁移失败。' >&2
            return 2
        }
        rm -f -- "$record" || return 2
    fi
    return 0
}
cloudflared_unshared() {
    local dir
    if grep -q '^cloudflared$' /proc/[0-9]*/comm 2>/dev/null; then
        return 1
    fi
    for dir in /etc/systemd/system /run/systemd/system /usr/lib/systemd/system /lib/systemd/system /etc/init.d /etc/cron.d; do
        [ -d "$dir" ] || continue
        if find "$dir" -type f -exec grep -Il -- cloudflared {} + 2>/dev/null | grep -q .; then
            return 1
        fi
    done
    for dir in /etc/cloudflared /usr/local/etc/cloudflared "$HOME/.cloudflared"; do
        [ ! -e "$dir" ] || return 1
    done
    return 0
}
offer_cloudflared_removal() {
    local candidate=""
    if [ -x /usr/local/lib/onebox/cloudflared ]; then candidate=/usr/local/lib/onebox/cloudflared
    else candidate=$(type -P cloudflared) || candidate=""; fi
    if [ -z "$candidate" ] &&
       [ ! -e /usr/local/lib/onebox/cloudflared ] &&
       [ ! -L /usr/local/lib/onebox/cloudflared ]; then
        return 0
    fi
    local owner_rc=0
    cloudflared_owner_valid || owner_rc=$?
    if [ "$owner_rc" = 2 ]; then return 1; fi
    if [ "$owner_rc" != 0 ]; then
        printf '[提示] cloudflared 非本脚本可确认的组件，已保留。\n'
        return 0
    fi
    if ! cloudflared_unshared; then
        printf '[提示] cloudflared 疑似被其他隧道使用，已保留。\n'
        return 0
    fi
    if ! rm -f -- /usr/local/lib/onebox/cloudflared; then
        printf '[错误] 本脚本安装的 cloudflared 删除失败，归属记录已保留。\n' >&2
        return 1
    fi
    rm -f -- "$CLOUDFLARED_OWNER_FILE" || return 1
    printf '[完成] 已卸载本脚本安装的 cloudflared。\n'
}
ui_line() { printf '%b%s%b\n' "$CYAN" '------------------------------' "$PLAIN"; }
ui_title() {
    printf '\n'
    ui_line
    printf '  %s\n' "$1"
    ui_line
}
ui_item() { printf '  %b[%s]%b %s\n' "$CYAN" "$1" "$PLAIN" "$2"; }
ui_clear() {
    if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
        printf '\033[H\033[2J'
    else
        printf '\n'
    fi
}

cleanup_acme_cron() {
    local cron_text tmp rc
    cron_text=$(crontab -l 2>/dev/null); rc=$?
    if [ "$rc" != 0 ]; then
        # No table is a normal outcome; other failures must not erase anything.
        if [ "$rc" = 1 ] && [ -z "$cron_text" ]; then return 0; fi
        return 1
    fi
    tmp=$(mktemp "$CONFIG_DIR/.cron-cleanup.XXXXXX") || return 1
    SB_OWNED_TEMP_FILES+=("$tmp")
    printf '%s\n' "$cron_text" | awk -v path="$ACME_HOME" 'index($0,path)==0' > "$tmp" || return 1
    crontab "$tmp" || return 1
    rm -f "$tmp"
}

uninstall_all() {
    local un
    ask "确认卸载脚本、sing-box和所有节点配置吗？(y/n): " un
    [[ "$un" == "y" || "$un" == "Y" ]] || return 2
    if [[ "$un" == "y" || "$un" == "Y" ]]; then
        load_secrets || return 1
        local svc
        local -a services=(onebox) registered=()
        IFS=',' read -r -a registered <<< "${ARGO_SERVICES:-}"
        for svc in "${registered[@]}"; do
            [ -n "$svc" ] || continue
            [[ "$svc" =~ ^cloudflared-[A-Za-z0-9_-]+$ ]] || {
                echo '服务登记记录无效，取消卸载。' >&2
                return 1
            }
            services+=("$svc")
        done
        for svc in "${services[@]}"; do
            if ! run_step "停止并禁用 ${svc}" stop_managed_service "$svc"; then
                echo '卸载暂停：未删除程序和配置。部分服务可能已停止，请检查后重试。' >&2
                return 1
            fi
        done
        remove_all_fw_rules || {
            echo '卸载暂停：防火墙清理失败，未删除程序和配置；服务已停止。' >&2
            return 1
        }
        for svc in "${services[@]}"; do
            if [ "$SERVICE_MANAGER" = openrc ]; then
                rm -f -- "/etc/init.d/$svc" || return 1
            else
                rm -f -- "/etc/systemd/system/$svc.service" || return 1
            fi
        done
        if [ "$SERVICE_MANAGER" != openrc ]; then systemctl daemon-reload || return 1; fi
        if [ "$SERVICE_MANAGER" = openrc ]; then
            rm -f /var/run/onebox.pid || return 1
            for svc in "${registered[@]}"; do
                [ -z "$svc" ] || rm -f -- "/var/run/$svc.pid" || return 1
            done
        fi

        if [ -d "$ACME_HOME" ]; then
            ensure_deps crontab || return 1
            cleanup_acme_cron || return 1
            rm -rf -- "$ACME_HOME" || return 1
        fi

        offer_cloudflared_removal || return 1
        offer_bbr_restore || return 1
        # Preserve an externally modified/shared component, even inside the fixed directory.
        if [ -e /usr/local/lib/onebox/cloudflared ]; then
            echo '[错误] cloudflared 无法确认可安全删除，卸载暂停并保留程序目录。' >&2
            return 1
        fi
        rm -rf /usr/local/lib/onebox /usr/local/bin/onebox /etc/onebox /var/log/onebox || return 1
        if [ ! -d "$BBR_STATE_DIR" ]; then rm -rf /var/lib/onebox || return 1
        else printf '[提示] 按要求保留 BBR 及其恢复记录：%s\n' "$BBR_STATE_DIR"; fi
        rm -f /run/lock/onebox.lock || return 1

        echo -e "${GREEN}[完成] 已卸载 sing-box、管理脚本和节点配置。${PLAIN}"
    fi
}

menu() {
    local choice=""
    ensure_deps jq || return 1
    local LATEST_VER_CACHE
    LATEST_VER_CACHE=$(get_latest_version)
    GLOBAL_LATEST_VER="$LATEST_VER_CACHE"

    while true; do
        ui_clear
        SB_STATUS=$(managed_service_state onebox)
        [ "$SB_STATUS" == "active" ] && ST_COLOR=$GREEN || ST_COLOR=$RED

        VER=$( ( /usr/local/lib/onebox/sing-box version ) 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        if [ -n "$VER" ]; then
            if [ -n "$GLOBAL_LATEST_VER" ] && [ "$VER" != "$GLOBAL_LATEST_VER" ]; then VER_SHOW="${VER} ${YELLOW}[新版: ${GLOBAL_LATEST_VER}]${PLAIN}"
            else VER_SHOW="${VER}"
            fi
        else
            VER_SHOW="未安装"
        fi

        echo -e "------------- onebox 管理脚本 -------------"
        printf '%s\n' '仅供学习与技术研究，请遵守适用法律法规，在获得授权的环境中使用。'
        printf '系统: Linux %s | 包管理: %s | 服务管理: %s\n' "$ARCH" "$PACKAGE_MANAGER" "$SERVICE_MANAGER"
        echo -e "sing-box ${VER_SHOW}: ${ST_COLOR}${SB_STATUS}${PLAIN}\n"
        echo -e " 1) 添加节点"
        echo -e " 2) 更改节点"
        echo -e " 3) 删除节点"
        echo -e " 4) 查看节点"
        echo -e " 5) 证书管理"
        echo -e " 6) 运行管理"
        echo -e " 7) 更新"
        echo -e " 8) 其他"
        echo -e " 9) 卸载"
        echo -e " 0) 退出\n"
        ask "请选择 [0-9]: " choice

        case "$choice" in
            1) init_base && add_config ;;
            2) require_config && modify_config ;;
            3) require_config && del_config ;;
            4) view_config ;;
            5) mkdir -p "$CONFIG_DIR" "$CERT_DIR" && chmod 700 "$CONFIG_DIR" "$CERT_DIR" && cert_manage ;;
            6) run_manage ;;
            7) init_base && update_manage ;;
            8) require_config && other_manage ;;
            9)
                if uninstall_all; then exit 0
                else
                    local un_rc=$?
                    [ "$un_rc" -eq 2 ] || exit "$un_rc"
                fi
                ;;
            0) exit 0 ;;
            *) echo "  [提示] 选项无效，请重新输入。"; sleep 1 ;;
        esac
        if [ "${CONFIG_TX_BLOCKED:-0}" = 1 ]; then
            echo '存在未完成恢复的事务，退出管理面板；请保留备份并人工检查。' >&2
            exit 1
        fi
    done
}

commit_config() {
    if [ "${CONFIG_TX_BLOCKED:-0}" = 1 ]; then
        echo '事务被阻塞，拒绝删除备份。' >&2
        return 1
    fi
    rm -f "${CONFIG_FILE}.bak" || return 1
    if [ -n "${CONFIG_TX_DIR:-}" ]; then
        rm -rf "$CONFIG_TX_DIR" || return 1
        CONFIG_TX_DIR=""
    fi
    CONFIG_TX_ARGO_PENDING=""
}

rename_argo_registration() {
    local old="$1" new="$2" svc updated="" seen=0
    local -a registered=()
    [[ "$old" =~ ^cloudflared-[A-Za-z0-9_-]+$ ]] || return 1
    [[ "$new" =~ ^cloudflared-[A-Za-z0-9_-]+$ ]] || return 1
    load_secrets || return 1
    IFS=',' read -r -a registered <<< "${ARGO_SERVICES:-}"
    for svc in "${registered[@]}"; do
        [ -n "$svc" ] || continue
        [[ "$svc" =~ ^cloudflared-[A-Za-z0-9_-]+$ ]] || {
            echo '隧道服务登记记录无效，拒绝覆盖。' >&2
            return 1
        }
        [ "$svc" != "$old" ] || svc="$new"
        if [ "$svc" = "$new" ]; then
            [ "$seen" = 0 ] || continue
            seen=1
        fi
        updated="${updated:+${updated},}${svc}"
    done
    [ "$seen" = 1 ] || updated="${updated:+${updated},}${new}"
    save_secret ARGO_SERVICES "$updated" || return 1
    ARGO_SERVICES="$updated"
}

rename_argo_service() {
    local old="$1" new="$2" src dst d enabled=0 active=0
    [[ "$old" =~ ^[A-Za-z0-9_-]+$ && "$new" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    if [ "$SERVICE_MANAGER" = openrc ]; then
        src="/etc/init.d/cloudflared-$old"; dst="/etc/init.d/cloudflared-$new"
        [ -e "/etc/runlevels/default/cloudflared-$old" ] && enabled=1
        rc-service "cloudflared-$old" status >/dev/null 2>&1 && active=1
    else
        src="/etc/systemd/system/cloudflared-$old.service"; dst="/etc/systemd/system/cloudflared-$new.service"
        systemctl is-enabled --quiet "cloudflared-$old" && enabled=1
        systemctl is-active --quiet "cloudflared-$old" && active=1
    fi
    if [ ! -f "$src" ] || [ -e "$dst" ] || [ -L "$dst" ]; then
        printf '%s\n' '原 Argo 服务文件缺失或目标服务文件已存在，取消重命名。' >&2
        return 1
    fi
    d=$(mktemp -d "$CONFIG_DIR/.argo-rename.XXXXXX") || return 1
    cp -p "$src" "$d/original" || { rm -rf "$d"; return 1; }
    if [ "$SERVICE_MANAGER" = openrc ]; then
        if rc-service "cloudflared-$old" stop &&
           rc-update del "cloudflared-$old" default &&
           mv "$src" "$dst" &&
           sed -i "s/cloudflared-$old/cloudflared-$new/g" "$dst" &&
           { [ "$enabled" = 0 ] || rc-update add "cloudflared-$new" default; } &&
           { [ "$active" = 0 ] || { rc-service "cloudflared-$new" start && rc-service "cloudflared-$new" status >/dev/null 2>&1; }; } &&
           rename_argo_registration "cloudflared-$old" "cloudflared-$new"; then
            rm -rf "$d"
            return 0
        fi
        rc-service "cloudflared-$new" stop >/dev/null 2>&1
        rc-update del "cloudflared-$new" default >/dev/null 2>&1
    else
        if systemctl stop "cloudflared-$old" &&
           systemctl disable "cloudflared-$old" &&
           mv "$src" "$dst" &&
           sed -i "s/tunnel for $old/tunnel for $new/g" "$dst" &&
           systemctl daemon-reload &&
           { [ "$enabled" = 0 ] || systemctl enable "cloudflared-$new"; } &&
           { [ "$active" = 0 ] || { systemctl start "cloudflared-$new" && systemctl is-active --quiet "cloudflared-$new"; }; } &&
           rename_argo_registration "cloudflared-$old" "cloudflared-$new"; then
            rm -rf "$d"
            return 0
        fi
        systemctl stop "cloudflared-$new" >/dev/null 2>&1
        systemctl disable "cloudflared-$new" >/dev/null 2>&1
    fi
    if ! cp -p "$d/original" "$src" || ! rm -f "$dst"; then
        printf 'Argo 文件恢复失败，备份保留在 %s\n' "$d" >&2
        return 1
    fi
    local failed=0
    if [ "$SERVICE_MANAGER" = openrc ]; then
        if [ "$enabled" = 1 ]; then rc-update add "cloudflared-$old" default || failed=1; fi
        if [ "$active" = 1 ]; then rc-service "cloudflared-$old" start || failed=1; fi
    else
        systemctl daemon-reload || failed=1
        if [ "$enabled" = 1 ]; then systemctl enable "cloudflared-$old" || failed=1; fi
        if [ "$active" = 1 ]; then systemctl start "cloudflared-$old" || failed=1; fi
    fi
    if [ "$failed" = 0 ]; then rm -rf "$d"; else printf 'Argo 服务恢复失败，备份: %s\n' "$d" >&2; fi
    return 1
}

remove_fw_record() {
    local p="$1" proto="$2" tmp
    check_port_in_config "$p" "$proto" && return 0
    [ -f "$FW_PORTS_FILE" ] || return 0
    tmp=$(mktemp "${FW_PORTS_FILE}.tmp.XXXXXX") || return 1
    SB_OWNED_TEMP_FILES+=("$tmp")
    if awk -F/ -v p="$p" -v proto="$proto" \
        '!($1 == p && ($2 == proto || (proto == "both" && ($2 == "tcp" || $2 == "udp"))))' \
        "$FW_PORTS_FILE" > "$tmp" && mv -f "$tmp" "$FW_PORTS_FILE"; then return 0; fi
    rm -f "$tmp"; return 1
}

service_is_active() {
    if [ "$SERVICE_MANAGER" = openrc ]; then
        rc-service onebox status >/dev/null 2>&1
    else
        systemctl is-active --quiet onebox
    fi
}

snapshot_service_state() {
    local d="$1" active=0 enabled=0
    service_is_active && active=1
    if [ "$SERVICE_MANAGER" = openrc ]; then
        [ -e /etc/runlevels/default/onebox ] && enabled=1
    else
        systemctl is-enabled --quiet onebox 2>/dev/null && enabled=1
    fi
    printf '%s\n' "$active" > "$d/service.active" &&
    printf '%s\n' "$enabled" > "$d/service.enabled"
}

restore_service_state() {
    local d="$1" active enabled failed=0
    IFS= read -r active < "$d/service.active" || return 1
    IFS= read -r enabled < "$d/service.enabled" || return 1
    case "$active:$enabled" in 0:0|0:1|1:0|1:1) ;; *) return 1 ;; esac
    if [ "$active" = 1 ]; then
        restart_service || failed=1
    elif service_is_active; then
        if [ "$SERVICE_MANAGER" = openrc ]; then
            rc-service onebox stop || failed=1
        else
            systemctl stop onebox || failed=1
        fi
        if service_is_active; then failed=1; fi
    fi
    if [ "$SERVICE_MANAGER" = openrc ]; then
        if [ "$enabled" = 1 ]; then
            if [ -e /etc/init.d/onebox ]; then rc-update add onebox default || failed=1; else failed=1; fi
        elif [ -e /etc/runlevels/default/onebox ]; then
            rc-update del onebox default || failed=1
        fi
    elif [ "$enabled" = 1 ]; then
        if [ -e /etc/systemd/system/onebox.service ]; then systemctl enable onebox >/dev/null 2>&1 || failed=1; else failed=1; fi
    elif systemctl is-enabled --quiet onebox 2>/dev/null; then
        systemctl disable onebox >/dev/null 2>&1 || failed=1
    fi
    return "$failed"
}

cleanup_created_argo_service() {
    if cleanup_created_argo_service_impl "$1"; then
        if [ "${CONFIG_TX_ARGO_PENDING:-}" = "$1" ]; then
            CONFIG_TX_ARGO_PENDING=""
        fi
        return 0
    fi
    CONFIG_TX_BLOCKED=1
    printf '隧道清理失败，事务已阻塞；备份保留在 %s。请人工恢复后重新运行。\n' "${CONFIG_TX_DIR:-unknown}" >&2
    return 1
}

managed_tunnel_token_file() {
    local svc="$1" file path
    if [ "$SERVICE_MANAGER" = openrc ]; then file="/etc/init.d/$svc"
    else file="/etc/systemd/system/$svc.service"; fi
    [ -f "$file" ] || return 0
    path=$(sed -n 's/.*--token-file \([^ " ]*\).*/\1/p' "$file" | head -n 1)
    case "$path" in
        /etc/onebox/.tunnel-token.*)
            [[ "${path##*/}" =~ ^\.tunnel-token\.[A-Za-z0-9]+$ ]] || return 1
            printf '%s\n' "$path" ;;
    esac
}

backup_argo_service_for_delete() {
    local tag="$1" d="${CONFIG_TX_DIR:-}/argo-delete" svc unit token state rc active=0 enabled=0
    [ -n "${CONFIG_TX_DIR:-}" ] && [[ "$tag" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    svc="cloudflared-$tag"
    if [ "$SERVICE_MANAGER" = openrc ]; then unit="/etc/init.d/$svc"
    else unit="/etc/systemd/system/$svc.service"; fi
    mkdir "$d" || return 1
    if [ -f "$unit" ]; then cp -p "$unit" "$d/unit" || return 1
    else : > "$d/unit.absent" || return 1; fi
    token=$(managed_tunnel_token_file "$svc") || return 1
    printf '%s\n' "$token" > "$d/token-path" || return 1
    if [ -n "$token" ] && [ -e "$token" ]; then
        [ -f "$token" ] && cp -p "$token" "$d/token" || return 1
    fi
    if [ "$SERVICE_MANAGER" = openrc ]; then
        if [ -f "$unit" ]; then
            rc=0
            rc-service "$svc" status >/dev/null 2>&1 || rc=$?
            case "$rc" in 0) active=1 ;; 3) ;; *) return 1 ;; esac
        fi
        if [ -e "/etc/runlevels/default/$svc" ] || [ -L "/etc/runlevels/default/$svc" ]; then enabled=1; fi
    else
        state=$(systemctl show "$svc" -p LoadState --value) || return 1
        case "$state" in
            not-found) ;;
            loaded)
                state=$(systemctl show "$svc" -p ActiveState --value) || return 1
                case "$state" in active|activating|reloading) active=1 ;; inactive|failed) ;; *) return 1 ;; esac
                state=$(systemctl show "$svc" -p UnitFileState --value) || return 1
                case "$state" in enabled) enabled=1 ;; disabled) ;; *) return 1 ;; esac ;;
            *) return 1 ;;
        esac
    fi
    # Publish the marker only after all files and state are safely backed up.
    printf '%s\n' "$active" > "$d/active" &&
    printf '%s\n' "$enabled" > "$d/enabled" &&
    printf '%s\n' "$tag" > "$d/tag.tmp" && mv -f "$d/tag.tmp" "$d/tag"
}

restore_argo_file() {
    local source="$1" target="$2" tmp
    tmp=$(mktemp "${target}.restore.XXXXXX") || return 1
    SB_OWNED_TEMP_FILES+=("$tmp")
    if cp -p "$source" "$tmp" && mv -f "$tmp" "$target"; then return 0; fi
    rm -f "$tmp"
    return 1
}

restore_deleted_argo_service_files() {
    local d="$1/argo-delete" tag svc unit token
    [ -f "$d/tag" ] || return 0
    IFS= read -r tag < "$d/tag" && [[ "$tag" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    IFS= read -r token < "$d/token-path" || return 1
    if [ -n "$token" ]; then
        [[ "$token" =~ ^/etc/onebox/\.tunnel-token\.[A-Za-z0-9]+$ ]] || return 1
    fi
    svc="cloudflared-$tag"
    if [ "$SERVICE_MANAGER" = openrc ]; then unit="/etc/init.d/$svc"
    else unit="/etc/systemd/system/$svc.service"; fi
    [ -f "$d/unit" ] || [ -f "$d/unit.absent" ] || return 1
    stop_managed_service "$svc" || return 1
    if [ -n "$token" ]; then
        if [ -f "$d/token" ]; then restore_argo_file "$d/token" "$token" || return 1
        else rm -f -- "$token" || return 1; fi
    fi
    if [ -f "$d/unit" ]; then restore_argo_file "$d/unit" "$unit" || return 1
    else rm -f -- "$unit" || return 1; fi
    if [ "$SERVICE_MANAGER" != openrc ]; then systemctl daemon-reload || return 1; fi
    return 0
}

restore_deleted_argo_service_state() {
    local d="$1/argo-delete" tag svc active enabled rc state
    [ -f "$d/tag" ] || return 0
    IFS= read -r tag < "$d/tag" && [[ "$tag" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    IFS= read -r active < "$d/active" && IFS= read -r enabled < "$d/enabled" || return 1
    case "$active:$enabled" in 0:0|0:1|1:0|1:1) ;; *) return 1 ;; esac
    svc="cloudflared-$tag"
    if [ -f "$d/unit.absent" ]; then [ "$active:$enabled" = 0:0 ]; return $?; fi
    if [ "$SERVICE_MANAGER" = openrc ]; then
        if [ "$enabled" = 1 ]; then rc-update add "$svc" default || return 1
        elif [ -e "/etc/runlevels/default/$svc" ] || [ -L "/etc/runlevels/default/$svc" ]; then rc-update del "$svc" default || return 1; fi
        if [ "$active" = 1 ]; then
            rc-service "$svc" start && rc-service "$svc" status >/dev/null 2>&1 || return 1
        else
            rc=0
            rc-service "$svc" status >/dev/null 2>&1 || rc=$?
            case "$rc" in 0) rc-service "$svc" stop || return 1 ;; 3) ;; *) return 1 ;; esac
            rc=0
            rc-service "$svc" status >/dev/null 2>&1 || rc=$?
            [ "$rc" = 3 ] || return 1
        fi
    else
        if [ "$enabled" = 1 ]; then systemctl enable "$svc" >/dev/null 2>&1 || return 1
        else systemctl disable "$svc" >/dev/null 2>&1 || return 1; fi
        if [ "$active" = 1 ]; then
            systemctl start "$svc" && systemctl is-active --quiet "$svc" || return 1
        else
            systemctl stop "$svc" || return 1
            state=$(systemctl show "$svc" -p ActiveState --value) || return 1
            case "$state" in inactive|failed) ;; *) return 1 ;; esac
        fi
    fi
    return 0
}

cleanup_created_argo_service_impl() {
    local tag="$1" svc token_file
    [[ "$tag" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    svc="cloudflared-$tag"
    token_file=$(managed_tunnel_token_file "$svc") || return 1
    stop_managed_service "$svc" || return 1
    if [ "$SERVICE_MANAGER" = openrc ]; then
        rm -f -- "/etc/init.d/$svc" || return 1
    else
        rm -f -- "/etc/systemd/system/$svc.service" || return 1
        systemctl daemon-reload || return 1
    fi
    [ -z "$token_file" ] || rm -f -- "$token_file" || return 1
    return 0
}

backup_config() {
    if [ -n "${CONFIG_TX_DIR:-}" ]; then
        printf '%s\n' '上一次配置事务尚未结束，拒绝覆盖备份。' >&2
        return 1
    fi
    local d
    d=$(mktemp -d "$CONFIG_DIR/.transaction.XXXXXX") || return 1
    if ! cp -p "$CONFIG_FILE" "$d/config.json"; then rm -rf "$d"; return 1; fi
    if [ -e "$SECRETS_FILE" ]; then
        if ! cp -p "$SECRETS_FILE" "$d/secrets"; then rm -rf "$d"; return 1; fi
    else
        touch "$d/secrets.absent" || { rm -rf "$d"; return 1; }
    fi
    if ! cp -p "$CONFIG_FILE" "${CONFIG_FILE}.bak"; then rm -rf "$d"; return 1; fi
    if ! snapshot_service_state "$d"; then rm -rf "$d"; return 1; fi
    CONFIG_TX_DIR="$d"
}
restore_config_and_service() {
    if [ "${CONFIG_TX_BLOCKED:-0}" = 1 ]; then
        echo '事务已阻塞，跳过自动恢复，保留配置、密钥和备份供人工处理。' >&2
        return 1
    fi
    local d="${CONFIG_TX_DIR:-}" active enabled
    if [ -z "$d" ] || [ ! -f "$d/config.json" ]; then
        printf '%s\n' '缺少完整事务备份，拒绝不完整恢复。' >&2
        return 1
    fi
    if ! IFS= read -r active < "$d/service.active" ||
       ! IFS= read -r enabled < "$d/service.enabled"; then
        echo '服务状态备份缺失，拒绝修改当前配置。' >&2
        return 1
    fi
    case "$active:$enabled" in
        0:0|0:1|1:0|1:1) ;;
        *) echo '服务状态备份无效，拒绝修改当前配置。' >&2; return 1 ;;
    esac
    if [ ! -f "$d/secrets.absent" ] && [ ! -f "$d/secrets" ]; then
        echo '密钥备份缺失，拒绝修改当前配置。' >&2
        return 1
    fi
    if [ -n "${CONFIG_TX_ARGO_PENDING:-}" ]; then
        cleanup_created_argo_service "$CONFIG_TX_ARGO_PENDING" || return 1
    fi
    if ! restore_deleted_argo_service_files "$d"; then
        printf '隧道文件恢复失败；备份保留在 %s\n' "$d" >&2
        return 1
    fi
    local restore_tmp
    restore_tmp=$(mktemp "${CONFIG_FILE}.restore.XXXXXX") || return 1
    SB_OWNED_TEMP_FILES+=("$restore_tmp")
    if ! cp -p "$d/config.json" "$restore_tmp" || ! mv -f "$restore_tmp" "$CONFIG_FILE"; then
        rm -f "$restore_tmp"
        return 1
    fi
    if [ -f "$d/secrets.absent" ]; then
        rm -f "$SECRETS_FILE" || return 1
    else
        restore_tmp=$(mktemp "${SECRETS_FILE}.restore.XXXXXX") || return 1
        SB_OWNED_TEMP_FILES+=("$restore_tmp")
        if ! cp -p "$d/secrets" "$restore_tmp" || ! mv -f "$restore_tmp" "$SECRETS_FILE"; then
            rm -f "$restore_tmp"
            return 1
        fi
    fi
    load_secrets || return 1
    if ! restore_service_state "$d"; then
        printf '配置与 secrets 已恢复，但服务恢复失败；备份保留在 %s\n' "$d" >&2
        return 1
    fi
    if ! restore_deleted_argo_service_state "$d"; then
        printf '隧道运行状态恢复失败；备份保留在 %s\n' "$d" >&2
        return 1
    fi
    commit_config
}

valid_tunnel_token_format() {
    [ "${#1}" -ge 64 ] && [ "${#1}" -le 16384 ] && [[ "$1" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]
}

valid_tunnel_token() {
    local decoded
    valid_tunnel_token_format "$1" || return 1
    decoded=$(printf '%s' "$1" | base64 -d 2>/dev/null) || return 1
    printf '%s' "$decoded" | jq -e '
      type == "object" and
      (.a | type == "string" and length > 0) and
      (.s | type == "string" and length > 0) and
      (.t | type == "string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))
    ' >/dev/null 2>&1 || return 1
}

managed_tunnel_metrics_addr() {
    local svc="$1" file addr port
    [[ "$svc" =~ ^cloudflared-[A-Za-z0-9_-]+$ ]] || return 1
    if [ "$SERVICE_MANAGER" = openrc ]; then file="/etc/init.d/$svc"
    else file="/etc/systemd/system/$svc.service"; fi
    [ -r "$file" ] || return 1
    addr=$(sed -n 's/.*--metrics \(127\.0\.0\.1:[0-9]*\).*/\1/p' "$file" | head -n 1)
    port="${addr##*:}"
    [[ "$addr" == 127.0.0.1:* && "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ] || return 1
    printf '%s\n' "$addr"
}

tunnel_is_ready() {
    local body
    body=$(curl --noproxy '*' -fsS --connect-timeout 1 --max-time 2 "http://$1/ready" 2>/dev/null) || return 1
    printf '%s' "$body" | jq -e '.readyConnections | type == "number" and . > 0' >/dev/null 2>&1 || return 1
}

wait_tunnel_ready() {
    local addr="$1" tag="$2" attempt
    for ((attempt=0; attempt<15; attempt++)); do
        if tunnel_is_ready "$addr"; then return 0; fi
        sleep 2
    done
    printf '[错误] 未确认连接到 Cloudflare；请检查 Token 是否有效，以及 DNS 和出站 TCP 7844 是否可达。\n' >&2
    if [ "$SERVICE_MANAGER" = systemd ]; then
        printf '连接器日志：journalctl -u cloudflared-%s.service --no-pager -n 50\n' "$tag" >&2
    fi
    return 1
}

create_argo_service() {
    local tag="$1" bin="$2" token="$3" token_file unit metrics_port metrics_addr
    [[ "$tag" =~ ^[A-Za-z0-9_-]+$ && "$bin" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    valid_tunnel_token "$token" || return 1
    metrics_port=$(rand_port) || return 1
    metrics_addr="127.0.0.1:$metrics_port"
    token_file=$(mktemp "$CONFIG_DIR/.tunnel-token.XXXXXX") || return 1
    printf '%s' "$token" > "$token_file" && chmod 600 "$token_file" || { rm -f "$token_file"; return 1; }
    if [ "$SERVICE_MANAGER" = openrc ]; then unit="/etc/init.d/cloudflared-$tag"
    else unit="/etc/systemd/system/cloudflared-$tag.service"; fi
    if [ -e "$unit" ] || [ -L "$unit" ]; then rm -f "$token_file"; return 1; fi
    if ! (set -C; : > "$unit"); then rm -f "$token_file"; return 1; fi
    CONFIG_TX_ARGO_PENDING="$tag"
    if [ "$SERVICE_MANAGER" = openrc ]; then
        if ! cat > "$unit" <<EOF
#!/sbin/openrc-run
name="cloudflared-$tag"
command="$bin"
command_args="tunnel --no-autoupdate --protocol http2 --metrics $metrics_addr run --token-file $token_file"
command_background=true
pidfile="/var/run/cloudflared-$tag.pid"
depend() { need net; }
EOF
        then rm -f "$token_file"; return 1; fi
        chmod 755 "$unit" && rc-update add "cloudflared-$tag" default &&
        rc-service "cloudflared-$tag" start && rc-service "cloudflared-$tag" status || return 1
    else
        if ! cat > "$unit" <<EOF
[Unit]
Description=cloudflared tunnel for $tag
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$bin tunnel --no-autoupdate --protocol http2 --metrics $metrics_addr run --token-file $token_file
Restart=on-failure
RestartSec=10s
[Install]
WantedBy=multi-user.target
EOF
        then rm -f "$token_file"; return 1; fi
        chmod 644 "$unit" && systemctl daemon-reload && systemctl enable "cloudflared-$tag" --now &&
        systemctl is-active --quiet "cloudflared-$tag" || return 1
    fi
    run_step '等待隧道连接 Cloudflare' wait_tunnel_ready "$metrics_addr" "$tag" || return 1
    register_argo_service "cloudflared-$tag"
}

valid_host() {
    local value="$1" allow_ip="${2:-false}" label
    [ "${#value}" -le 253 ] || return 1
    if [ "$allow_ip" = true ] && [[ "$value" == *:* ]]; then
        [[ "$value" =~ ^[0-9A-Fa-f:]+$ && "$value" == *:*:* && "${#value}" -le 45 ]]
        return
    fi
    [[ "$value" =~ ^[A-Za-z0-9.-]+$ && "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1
    local -a labels=()
    IFS=. read -r -a labels <<< "$value"
    for label in "${labels[@]}"; do
        [ "${#label}" -le 63 ] && [[ "$label" != -* && "$label" != *- ]] || return 1
    done
}

read_secret_file() {
    local file="$1" destination="$2" content
    [ -f "$file" ] && [ -r "$file" ] && [ ! -L "$file" ] || die "密钥文件不可读、不是普通文件或是符号链接：$file" 2
    content=$(cat -- "$file") || die "读取密钥文件失败：$file"
    [ -n "$content" ] && [[ "$content" != *$'\n'* && "$content" != *$'\r'* ]] || die '密钥文件必须包含一行非空内容。' 2
    printf -v "$destination" '%s' "$content"
}

cli_help() {
    cat <<'EOF'
onebox 仅供学习与技术研究，请遵守适用法律法规，在获得授权的环境中使用。
用法: sh install.sh <命令> [选项]  或  onebox <命令> [选项]
直接运行 install.sh 默认无交互安装 VLESS + Reality，端口 443。
安装后的 onebox 不带参数进入菜单；onebox -n 使用上述默认安装。
显式使用 menu 进入交互菜单；指定其他命令即为无交互模式。
命令:
  install          安装到 /usr/local/bin/onebox（可指定 --version）
  add              添加一个节点（自动安装缺少的依赖及内核）
  delete           删除节点，需要 --tag NAME --yes
  list | links     节点列表 / 分享链接（--tag 可筛选）
  status | check   服务状态 / 配置检查
  doctor           只读体检：程序、配置 JSON、服务、隧道和证书
  logs             最近 80 行服务日志（systemd），--source install 查看安装步骤日志
  start | stop | restart
  update           更新 sing-box 内核（--version latest 或 x.y.z）
  update-script    从项目 GitHub main 分支更新管理脚本
  cert             生成/申请证书（--cert self|real）
  outbound         设置出站（--strategy auto|ipv4_only|ipv6_only）
  bbr              启用 BBR+FQ；内核或外部配置不允许时返回失败
  uninstall        卸载，需要 --yes；默认恢复本脚本管理的 BBR
add 选项:
  --protocol reality|hysteria2|tuic|anytls|argo|shadowsocks
  --tag NAME --port 1..65535 --uuid UUID --password VALUE
  --password-file PATH（或环境变量 SB_PASSWORD）
  --sni DOMAIN                 指定 Reality 伪装域名；省略则自动检测选第一名
                               自签证书域名默认 bing.com
Reality SNI 自动检测选项（仅 add --protocol reality）:
  --sni-region all|global|us|eu|jp|hk|sg|cn|au|kr（默认 all）
  --sni-category all|cdn,cloud,tech,fin,edu,media,social,gaming,ecom,region
                               默认 all；与地区筛选取交集，地区包含全球通用站
  --sni-hosts 'HOST URL ...'    自定义列表替代内置列表，空格/逗号分隔
                               不与地区/分类筛选混用；排除 Apple 旗下域名
  --sni-jobs 1..16             并发上限，默认 8；按剩余 PID 额度自动下调
  --sni-samples 1..5           每站测速次数，默认 3，取最小值
  --sni-timeout 1..15          每次请求超时秒数，默认 5
                               短证书链优先、同组按耗时排名；--sni 跳过检测
其他 add 选项:
  --cert self|real             默认 self
  --method METHOD              SS 默认 aes-128-gcm
  --firewall auto|skip         默认 auto
  --address IP_OR_HOST         分享链接地址（省略则自动获取公网 IP）
argo 选项:
  --domain DOMAIN --tunnel-token-file PATH（完整连接器 Token，不是隧道 ID）
  --edge HOST 可选，默认连接自己的隧道域名；也可通过 SB_TUNNEL_TOKEN 提供 Token
真实证书:
  --domain DOMAIN --validation dns|http（默认 dns）
  --cf-token-file PATH（或环境变量 CF_Token；也支持 CF_Key + CF_Email）
  --validation http 必须同时指定 --http01-ready
通用: --non-interactive/-n、--yes/-y、--help/-h
日志: --lines 1..1000、--source service|install；--tag NAME 查看已登记隧道
卸载: --keep-bbr 可保留网络参数和恢复记录
退出码: 0 成功；1 操作失败/服务未运行；2 参数错误；3 环境不支持；75 另一个操作正在运行
EOF
}

parse_cli() {
    CLI_COMMAND="" CLI_PROTOCOL="" CLI_TAG="" CLI_PORT="" CLI_UUID=""
    CLI_PASSWORD="${SB_PASSWORD:-}" CLI_TUNNEL_TOKEN="${SB_TUNNEL_TOKEN:-}"
    CLI_CERT=self CLI_METHOD=aes-128-gcm CLI_SNI="" CLI_DOMAIN=""
    CLI_SNI_REGION=all CLI_SNI_CATEGORIES=all CLI_SNI_HOSTS=""
    CLI_SNI_JOBS=8 CLI_SNI_SAMPLES=3 CLI_SNI_TIMEOUT=5
    CLI_VERSION=latest CLI_VALIDATION=dns CLI_HTTP01_READY=0 CLI_ADDRESS=""
    CLI_FIREWALL=y CLI_EDGE="" CLI_STRATEGY="" CLI_RESTORE_BBR=1
    CLI_LINES=80 CLI_LOG_SOURCE=service
    local option value
    local -a used_options=()
    while [ "$#" -gt 0 ]; do
        option="$1"; shift
        case "$option" in
            -h|--help|help) CLI_COMMAND=help; return 0 ;;
            -n|--non-interactive) NON_INTERACTIVE=1 ;;
            -y|--yes) ASSUME_YES=1 ;;
            --http01-ready) CLI_HTTP01_READY=1; used_options+=("$option") ;;
            --keep-bbr) CLI_RESTORE_BBR=0; used_options+=("$option") ;;
            --protocol|--tag|--port|--uuid|--password|--password-file|--tunnel-token-file|--cf-token-file|--cert|--method|--sni|--sni-region|--sni-category|--sni-hosts|--sni-jobs|--sni-samples|--sni-timeout|--domain|--version|--validation|--address|--edge|--strategy|--firewall|--lines|--source)
                [ "$#" -gt 0 ] && [[ "$1" != --* ]] || die "选项 $option 缺少值。" 2
                value="$1"; shift
                [ -n "$value" ] || die "选项 $option 不能为空。" 2
                used_options+=("$option")
                case "$option" in
                    --protocol) CLI_PROTOCOL="$value" ;;
                    --tag) CLI_TAG="$value" ;;
                    --port) CLI_PORT="$value" ;;
                    --uuid) CLI_UUID="$value" ;;
                    --password) CLI_PASSWORD="$value" ;;
                    --password-file) read_secret_file "$value" CLI_PASSWORD ;;
                    --tunnel-token-file) read_secret_file "$value" CLI_TUNNEL_TOKEN ;;
                    --cf-token-file) read_secret_file "$value" CF_Token ;;
                    --cert) CLI_CERT="$value" ;;
                    --method) CLI_METHOD="$value" ;;
                    --sni) CLI_SNI="$value" ;;
                    --sni-region) CLI_SNI_REGION="$value" ;;
                    --sni-category) CLI_SNI_CATEGORIES="$value" ;;
                    --sni-hosts) CLI_SNI_HOSTS="$value" ;;
                    --sni-jobs) CLI_SNI_JOBS="$value" ;;
                    --sni-samples) CLI_SNI_SAMPLES="$value" ;;
                    --sni-timeout) CLI_SNI_TIMEOUT="$value" ;;
                    --domain) CLI_DOMAIN="$value" ;;
                    --version) CLI_VERSION="${value#v}" ;;
                    --validation) CLI_VALIDATION="$value" ;;
                    --address) CLI_ADDRESS="$value" ;;
                    --edge) CLI_EDGE="$value" ;;
                    --strategy) CLI_STRATEGY="$value" ;;
                    --lines) CLI_LINES="$value" ;;
                    --source) CLI_LOG_SOURCE="$value" ;;
                    --firewall) case "$value" in auto) CLI_FIREWALL=y ;; skip) CLI_FIREWALL=n ;; *) die '--firewall 只能是 auto 或 skip。' 2 ;; esac ;;
                esac ;;
            -*) die "未知选项：$option" 2 ;;
            *) [ -z "$CLI_COMMAND" ] || die "只能指定一个命令，多余参数：$option" 2; CLI_COMMAND="$option" ;;
        esac
    done
    if [ -z "$CLI_COMMAND" ]; then
        if [ "${0##*/}" = onebox ] && [ "$NON_INTERACTIVE" = 0 ]; then
            CLI_COMMAND=menu
        else
            CLI_COMMAND=add
            CLI_PROTOCOL="${CLI_PROTOCOL:-reality}"
            CLI_PORT="${CLI_PORT:-443}"
        fi
    fi
    if [ "$CLI_COMMAND" = menu ]; then
        [ "$NON_INTERACTIVE" = 0 ] && [ -t 0 ] || die '交互菜单需要终端；无交互默认安装请使用 onebox -n。' 2
    fi
    [ "$CLI_COMMAND" = menu ] || NON_INTERACTIVE=1
    case "$CLI_COMMAND" in install|add|delete|list|links|status|check|doctor|logs|start|stop|restart|update|update-script|cert|outbound|bbr|uninstall|menu) ;; *) die "未知命令：$CLI_COMMAND（使用 --help 查看用法）。" 2 ;; esac
    # Reject irrelevant options rather than silently ignoring a typo in automation.
    for option in "${used_options[@]}"; do
        case "$CLI_COMMAND:$option" in
            add:--protocol|add:--tag|add:--port|add:--uuid|add:--password|add:--password-file|add:--tunnel-token-file|add:--cf-token-file|add:--cert|add:--method|add:--sni|add:--domain|add:--version|add:--validation|add:--address|add:--edge|add:--http01-ready|add:--firewall|install:--version|update:--version|delete:--tag|list:--tag|links:--tag|links:--address|cert:--cert|cert:--sni|cert:--domain|cert:--validation|cert:--cf-token-file|cert:--http01-ready|outbound:--strategy|uninstall:--keep-bbr) ;;
            logs:--lines|logs:--source|logs:--tag) ;;
            add:--sni-region|add:--sni-category|add:--sni-hosts|add:--sni-jobs|add:--sni-samples|add:--sni-timeout) ;;
            *) die "命令 $CLI_COMMAND 不接受选项 $option。" 2 ;;
        esac
    done
    [ -z "$CLI_TAG" ] || [[ "$CLI_TAG" =~ ^[A-Za-z0-9_-]+$ ]] || die '节点名称只能包含字母、数字、短横线和下划线。' 2
    [[ "$CLI_LINES" =~ ^[1-9][0-9]{0,3}$ ]] && [ "$CLI_LINES" -le 1000 ] || die '--lines 必须为 1–1000 的整数。' 2
    case "$CLI_LOG_SOURCE" in service|install) ;; *) die '--source 只能为 service 或 install。' 2 ;; esac
    [ "$CLI_LOG_SOURCE" != install ] || [ -z "$CLI_TAG" ] || die '--source install 不支持 --tag。' 2
    [ -z "$CLI_PORT" ] || { [[ "$CLI_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$CLI_PORT" -le 65535 ]; } || die '端口必须为 1–65535 的整数。' 2
    [ -z "$CLI_UUID" ] || [[ "$CLI_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die 'UUID 格式错误。' 2
    [[ "$CLI_PASSWORD" != *$'\n'* && "$CLI_PASSWORD" != *$'\r'* ]] || die '密码不能包含换行。' 2
    [ -z "$CLI_PASSWORD" ] || [[ "$CLI_PASSWORD" =~ [^[:space:]] ]] || die '密码不能全为空白。' 2
    [ "$CLI_VERSION" = latest ] || [[ "$CLI_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || die '版本格式应为 x.y.z 或 latest。' 2
    case "$CLI_CERT" in self|real) ;; *) die '--cert 只能为 self 或 real。' 2 ;; esac
    case "$CLI_VALIDATION" in dns|http) ;; *) die '--validation 只能为 dns 或 http。' 2 ;; esac
    case "$CLI_METHOD" in aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305|2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) ;; *) die '不支持的 Shadowsocks 加密方式。' 2 ;; esac
    if [ -n "${CF_Token:-}" ]; then [[ "$CF_Token" =~ ^[A-Za-z0-9_-]+$ ]] || die 'Cloudflare API Token 格式错误。' 2; fi
    local host
    for host in "$CLI_SNI" "$CLI_DOMAIN"; do [ -z "$host" ] || valid_host "$host" || die "域名格式错误：$host" 2; done
    for host in "$CLI_ADDRESS" "$CLI_EDGE"; do [ -z "$host" ] || valid_host "$host" true || die "地址格式错误：$host" 2; done
    valid_reality_sni_region "$CLI_SNI_REGION" || die '--sni-region 必须是 all/global/us/eu/jp/hk/sg/cn/au/kr。' 2
    valid_reality_sni_categories "$CLI_SNI_CATEGORIES" || die '--sni-category 含未知分类，请查看 --help。' 2
    [[ "$CLI_SNI_JOBS" =~ ^[1-9][0-9]?$ ]] && [ "$CLI_SNI_JOBS" -le 16 ] || die '--sni-jobs 必须为 1–16 的整数。' 2
    [[ "$CLI_SNI_SAMPLES" =~ ^[1-5]$ ]] || die '--sni-samples 必须为 1–5 的整数。' 2
    [[ "$CLI_SNI_TIMEOUT" =~ ^[1-9][0-9]?$ ]] && [ "$CLI_SNI_TIMEOUT" -le 15 ] || die '--sni-timeout 必须为 1–15 的整数。' 2
    if [ -n "$CLI_SNI_HOSTS" ]; then
        [ "$CLI_SNI_REGION" = all ] && [ "$CLI_SNI_CATEGORIES" = all ] || die '--sni-hosts 不与地区/分类筛选混用。' 2
        CLI_SNI_HOSTS=$(normalize_reality_sni_hosts "$CLI_SNI_HOSTS") || die '--sni-hosts 列表无效。' 2
    fi
    if [ "$CLI_COMMAND" = delete ] || [ "$CLI_COMMAND" = uninstall ]; then
        [ "$ASSUME_YES" = 1 ] || die "$CLI_COMMAND 必须显式指定 --yes。" 2
    fi
    if [ "$CLI_COMMAND" = delete ]; then [ -n "$CLI_TAG" ] || die 'delete 需要 --tag。' 2; fi
    if [ "$CLI_COMMAND" = outbound ]; then
        case "$CLI_STRATEGY" in auto|ipv4_only|ipv6_only) ;; *) die 'outbound 需要 --strategy auto|ipv4_only|ipv6_only。' 2 ;; esac
    fi
    if [ "$CLI_COMMAND" = add ]; then
        case "$CLI_PROTOCOL" in
            reality|vless-reality) CLI_PROTOCOL_INDEX=1 ;;
            hysteria2|hy2) CLI_PROTOCOL_INDEX=2 ;;
            tuic) CLI_PROTOCOL_INDEX=3 ;;
            anytls) CLI_PROTOCOL_INDEX=4 ;;
            argo|vless-argo) CLI_PROTOCOL_INDEX=5
                [ -n "$CLI_DOMAIN" ] || die 'Argo 需要 --domain。' 2
                valid_tunnel_token_format "$CLI_TUNNEL_TOKEN" || die 'Argo 需要完整 Tunnel Token（--tunnel-token-file 或 SB_TUNNEL_TOKEN）；不能使用隧道 ID、API Token 或 VLESS UUID。' 2 ;;
            shadowsocks|ss) CLI_PROTOCOL_INDEX=6 ;;
            *) die 'add 需要 --protocol reality|hysteria2|tuic|anytls|argo|shadowsocks。' 2 ;;
        esac
        for option in "${used_options[@]}"; do
            case "$option" in --sni-*) [ "$CLI_PROTOCOL_INDEX" = 1 ] || die "$option 仅适用于 Reality。" 2 ;; esac
        done
        if [ "$CLI_PROTOCOL_INDEX" = 1 ] && [ -n "$CLI_SNI" ]; then
            reality_sni_allowed_host "$CLI_SNI" || die 'Reality SNI 已排除 Apple 旗下域名，请使用其他域名。' 2
        fi
        if [ "$CLI_PROTOCOL_INDEX" = 6 ] && [ -n "$CLI_PASSWORD" ]; then
            # base64 is a base dependency on all supported distributions (including BusyBox).
            get_ss_pass_valid "$CLI_METHOD" "$CLI_PASSWORD" || die 'Shadowsocks 密码不符合所选加密方式。' 2
        fi
    fi
    if { [ "$CLI_COMMAND" = cert ] || { [ "$CLI_COMMAND" = add ] && [[ "$CLI_PROTOCOL_INDEX" =~ ^[234]$ ]]; }; } && [ "$CLI_CERT" = real ]; then
        [ -n "$CLI_DOMAIN" ] || die '真实证书需要 --domain。' 2
        if [ "$CLI_VALIDATION" = http ]; then
            [ "$CLI_HTTP01_READY" = 1 ] || die 'HTTP-01 需要 --http01-ready，并保证公网 80/TCP 长期可达。' 2
        elif [ -z "${CF_Token:-}" ] && { [ -z "${CF_Key:-}" ] || [ -z "${CF_Email:-}" ]; }; then
            die 'DNS 验证需要 --cf-token-file、CF_Token，或 CF_Key + CF_Email。' 2
        elif [ -z "${CF_Token:-}" ]; then
            [[ "$CF_Key" =~ ^[A-Za-z0-9]+$ ]] || die 'Cloudflare Global API Key 格式错误。' 2
            [[ "$CF_Email" =~ ^[^@]+@[^@]+\.[^@]+$ ]] || die 'Cloudflare 邮箱格式错误。' 2
        fi
    fi
}

require_config() {
    [ -f "$CONFIG_FILE" ] || { echo '[错误] 尚未安装，请先执行 install。' >&2; return 1; }
    if [ "${1:-}" = readonly ]; then
        command -v jq >/dev/null 2>&1 || { echo '[错误] 缺少 jq，请先安装后重试。' >&2; return 1; }
    else
        ensure_deps jq || return 1
    fi
    jq -e 'type == "object" and (.inbounds | type == "array")' "$CONFIG_FILE" >/dev/null || return 1
}

cli_outbound() {
    backup_config || return 1
    if [ "$CLI_STRATEGY" = auto ]; then
        apply_jq_config '(.outbounds[] | select(.tag=="direct")) |= del(.domain_strategy, .domain_resolver)' || return 1
    elif sb_ge_112; then
        apply_jq_config "$JQ_DNS_LOCAL | (.outbounds[] | select(.tag==\"direct\")) |= (del(.domain_strategy) | .domain_resolver = {\"server\": \"dns-local\", \"strategy\": \$s})" --arg s "$CLI_STRATEGY" || return 1
    else
        apply_jq_config '(.outbounds[] | select(.tag=="direct")).domain_strategy = $s' --arg s "$CLI_STRATEGY" || return 1
    fi
    restart_service && commit_config
}

managed_service_state() {
    local svc="$1" state rc=0
    [[ "$svc" == onebox || "$svc" =~ ^cloudflared-[A-Za-z0-9_-]+$ ]] || return 1
    if [ "$SERVICE_MANAGER" = openrc ]; then
        if [ ! -e "/etc/init.d/$svc" ] && [ ! -L "/etc/init.d/$svc" ]; then
            printf 'not-installed\n'; return 0
        fi
        rc-service "$svc" status >/dev/null 2>&1 || rc=$?
        case "$rc" in 0) state=active ;; 3) state=stopped ;; *) state=failed ;; esac
    else
        state=$(systemctl show "$svc" -p LoadState --value 2>/dev/null) || state=unknown
        case "$state" in
            not-found) printf 'not-installed\n'; return 0 ;;
            masked) printf 'masked\n'; return 0 ;;
            loaded) state=$(systemctl show "$svc" -p ActiveState --value 2>/dev/null) || state=unknown ;;
            *) state=unknown ;;
        esac
        case "$state" in active|inactive|failed|activating|deactivating|reloading) ;; *) state=unknown ;; esac
    fi
    printf '%s\n' "$state"
}

cli_status() {
    local state rc=0
    printf 'system: Linux %s; package-manager: %s; init: %s\n' "$ARCH" "$PACKAGE_MANAGER" "$SERVICE_MANAGER"
    if kernel_ok; then
        /usr/local/lib/onebox/sing-box version | head -n 1
    elif [ -e /usr/local/lib/onebox/sing-box ]; then
        printf 'sing-box: 无法运行\n'; rc=1
    else
        printf 'sing-box: 未安装\n'; rc=1
    fi
    if [ -r "$CONFIG_FILE" ]; then printf 'config: present\n'
    else printf 'config: missing-or-unreadable\n'; rc=1; fi
    state=$(managed_service_state onebox)
    printf 'service: %s\n' "$state"
    [ "$state" = active ] || rc=1
    return "$rc"
}

cli_doctor() {
    local rc=0 count certs cert days svc state metrics_addr
    local -a registered=()
    printf 'onebox 只读体检（不会安装依赖、下载脚本或更改服务）\n'
    cli_status || rc=1
    if ! command -v jq >/dev/null 2>&1; then
        printf '[待检查] 缺少 jq，无法检查配置 JSON 及引用证书；请安装 jq 后重试。\n'
        rc=1
    elif [ ! -r "$CONFIG_FILE" ] ||
         ! count=$(jq -er 'if type == "object" and (.inbounds | type) == "array" then (.inbounds | length) else error("invalid inbounds") end' "$CONFIG_FILE" 2>/dev/null); then
        printf '[异常] 配置 JSON 不可读或缺少 inbounds 数组。\n'
        rc=1
    else
        printf '[正常] 配置 JSON，节点数: %s；内核配置校验请执行 onebox check。\n' "$count"
        certs=$(jq -r --arg prefix "$CERT_DIR/" '[.inbounds[]?.tls.certificate_path? | select(type == "string") | select(startswith($prefix))] | unique[]' "$CONFIG_FILE" 2>/dev/null) || rc=1
        if [ -n "$certs" ]; then
            while IFS= read -r cert; do
                if ! command -v openssl >/dev/null 2>&1; then
                    printf '[待检查] 缺少 openssl，无法检查证书。\n'; rc=1; break
                elif ! openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1; then
                    printf '[异常] 证书缺失、不可读或已过期: %s\n' "$cert"; rc=1
                elif ! openssl x509 -in "$cert" -noout -checkend 604800 >/dev/null 2>&1; then
                    printf '[提醒] 证书将在 7 天内过期: %s\n' "$cert"; rc=1
                elif days=$(cert_remaining_days "$cert"); then
                    printf '[正常] 证书剩余 %s 天: %s\n' "$days" "$cert"
                else
                    printf '[正常] 证书有效且超过 7 天: %s\n' "$cert"
                fi
            done <<< "$certs"
        fi
    fi
    if ! load_secrets; then
        printf '[异常] 无法读取隧道服务登记记录。\n'; rc=1
    else
        IFS=',' read -r -a registered <<< "${ARGO_SERVICES:-}"
        for svc in "${registered[@]}"; do
            [ -n "$svc" ] || continue
            if [[ ! "$svc" =~ ^cloudflared-[A-Za-z0-9_-]+$ ]]; then
                printf '[异常] 隧道服务登记记录格式错误。\n'; rc=1; continue
            fi
            state=$(managed_service_state "$svc")
            printf 'tunnel %s: %s\n' "$svc" "$state"
            if [ "$state" != active ]; then
                rc=1
            elif ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
                printf '[待检查] 缺少 curl/jq，未确认隧道连接 Cloudflare。\n'; rc=1
            elif ! metrics_addr=$(managed_tunnel_metrics_addr "$svc"); then
                printf '[待检查] 旧隧道服务未配置本机 /ready 检查，进程运行不能证明连接成功。\n'; rc=1
            elif tunnel_is_ready "$metrics_addr"; then
                printf '[正常] 连接器已连接 Cloudflare；云端域名及 origin 映射仍需核对。\n'
            else
                printf '[异常] 连接器尚未连上 Cloudflare，请检查 Token、DNS、出站连接及隧道日志。\n'; rc=1
            fi
        done
    fi
    [ "$rc" = 0 ] || printf '[提示] 服务异常可执行 onebox logs；安装排障可执行 onebox logs --source install。\n'
    return "$rc"
}

cli_logs() {
    local svc=onebox file latest=""
    if [ "$CLI_LOG_SOURCE" = install ]; then
        for file in /var/log/onebox/step.*; do
            [ -f "$file" ] && [ ! -L "$file" ] || continue
            if [ -z "$latest" ] || [ "$file" -nt "$latest" ]; then latest="$file"; fi
        done
        [ -n "$latest" ] || { printf '[提示] 没有安装步骤日志。\n' >&2; return 1; }
        printf '安装步骤日志（执行中或失败保留）: %s\n' "$latest"
        tail -n "$CLI_LINES" -- "$latest"
        return $?
    fi
    if [ -n "$CLI_TAG" ]; then
        load_secrets || return 1
        svc="cloudflared-$CLI_TAG"
        case ",${ARGO_SERVICES:-}," in
            *",$svc,"*) ;;
            *) printf '[错误] 未登记此隧道服务: %s\n' "$CLI_TAG" >&2; return 1 ;;
        esac
    fi
    if [ "$SERVICE_MANAGER" = openrc ]; then
        printf '[提示] 当前 OpenRC 服务未配置运行日志落盘；可查看 onebox doctor 或 onebox logs --source install。\n' >&2
        return 3
    fi
    command -v journalctl >/dev/null 2>&1 || { printf '[错误] 缺少 journalctl。\n' >&2; return 1; }
    journalctl -u "$svc.service" --no-pager -n "$CLI_LINES"
}

cli_dispatch() {
    local version tag ip tags rc=0
    case "$CLI_COMMAND" in
        menu)
            if [ "$ONEBOX_SELF" != /usr/local/bin/onebox ]; then
                ensure_deps jq || return 1
                fetch_script "$ONEBOX_SELF" || return 1
            fi
            menu ;;
        install)
            printf '%s\n' '免责声明：仅供学习与技术研究，请遵守适用法律法规，在获得授权的环境中使用；使用风险由使用者承担。'
            init_base || return 1
            fetch_script "$ONEBOX_SELF" || return 1
            printf '[完成] 已安装：/usr/local/bin/onebox；配置：/etc/onebox。\n' ;;
        add)
            printf '%s\n' '免责声明：仅供学习与技术研究，请遵守适用法律法规，在获得授权的环境中使用；使用风险由使用者承担。'
            if [ "$CLI_PROTOCOL_INDEX" = 5 ] && [ -z "$CF_ARCH" ]; then echo '[错误] 此架构暂不支持 cloudflared。' >&2; return 3; fi
            init_base || return 1
            fetch_script "$ONEBOX_SELF" || return 1
            add_config ;;
        status) cli_status ;;
        doctor) cli_doctor ;;
        logs) cli_logs ;;
        uninstall) ensure_deps jq sha256sum || return 1; uninstall_all ;;
        update-script) fetch_script && printf '[完成] 管理脚本已更新。\n' ;;
        bbr) ensure_deps sysctl modprobe || return 1; enable_bbr ;;
        cert)
            ensure_deps openssl || return 1
            mkdir -p "$CONFIG_DIR" "$CERT_DIR" && chmod 700 "$CONFIG_DIR" "$CERT_DIR" || return 1
            if [ "$CLI_CERT" = self ]; then generate_self_cert; else apply_real_cert; fi ;;
        *)
            require_config || return 1
            case "$CLI_COMMAND" in
                list)
                    if [ -n "$CLI_TAG" ]; then
                        jq -e --arg tag "$CLI_TAG" '.inbounds[] | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null || return 1
                    fi
                    jq -r --arg tag "$CLI_TAG" '.inbounds[] | select($tag == "" or .tag == $tag) | [.tag,.type,(.listen_port|tostring)] | @tsv' "$CONFIG_FILE" ;;
                links)
                    if [ -n "$CLI_TAG" ]; then
                        jq -e --arg tag "$CLI_TAG" '.inbounds[] | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null || return 1
                    fi
                    ip=""
                    IP_LOOKUP_SKIPPED=0
                    if nodes_need_public_ip "$CLI_TAG"; then get_ip || :; ip=$GLOBAL_IP; fi
                    if [ "$IP_LOOKUP_SKIPPED" = 1 ]; then
                        printf '[提示] 进程额度不足，已跳过链接生成；请稍后重试，或用 --address 指定地址。\n' >&2
                        return 1
                    fi
                    tags=$(jq -r --arg tag "$CLI_TAG" '.inbounds[] | select($tag == "" or .tag == $tag) | .tag' "$CONFIG_FILE") || return 1
                    if [ -n "$tags" ]; then
                        while IFS= read -r tag; do build_share_url "$tag" "$ip" || rc=1; done <<< "$tags"
                    fi
                    return "$rc" ;;
                delete) del_config ;;
                check) check_kernel_config "$CONFIG_FILE" ;;
                start|restart) restart_service ;;
                stop) stop_sing_box_if_present ;;
                update)
                    ensure_deps curl wget tar gzip sha256sum || return 1
                    version="$CLI_VERSION"
                    [ "$version" != latest ] || version=$(get_latest_version)
                    [ -n "$version" ] || { echo '[错误] 无法取得最新版本；请指定 --version。' >&2; return 1; }
                    install_kernel "$version" restart ;;
                outbound) cli_outbound ;;
            esac ;;
    esac
}

main() {
    parse_cli "$@"
    if [ "$CLI_COMMAND" = help ]; then cli_help; return 0; fi
    detect_environment
    # Read-only inspection also works from a streamed script without fetching
    # another copy, creating a lock or bootstrapping missing dependencies.
    case "$CLI_COMMAND" in
        status|doctor|logs) cli_dispatch; return $? ;;
    esac
    trap cleanup_on_exit EXIT
    trap cleanup_on_interrupt INT
    trap 'exit 143' TERM
    prepare_script_path "${BASH_SOURCE[0]}" || return 1
    # util-linux flock closes its lock fd before exec so daemons cannot inherit it.
    if [ "${ONEBOX_LOCKED:-0}" != 1 ]; then
        ensure_deps flock || return 1
        if ! flock --help 2>&1 | grep -q -- '--close'; then
            if [ "$PACKAGE_MANAGER" = apk ]; then install_packages flock || return 1
            else install_packages util-linux || return 1; fi
            hash -r
        fi
        mkdir -p /run/lock || return 1
        env ONEBOX_LOCKED=1 flock -n -E 75 -o /run/lock/onebox.lock bash "$ONEBOX_SELF" "$@"
        local rc=$?
        [ "$rc" != 75 ] || printf '[错误] 另一个 onebox 操作正在运行。\n' >&2
        return "$rc"
    fi
    cli_dispatch
}

# ONEBOX_ENTRYPOINT
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
