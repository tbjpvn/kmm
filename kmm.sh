#!/bin/sh
# ================= Komari + Cloudflared 交互式管理脚本 =================
# 功能: 1) 部署安装  2) 升级 Komari  3) 更换 Cloudflare Token  4) 卸载
# 用法: sh komari_manager.sh
# =========================================================================

set -e

KOMARI_DIR="/opt/komari"
KOMARI_BIN="${KOMARI_DIR}/komari"
KOMARI_LOG="/var/log/komari.log"
CLOUDFLARED_LOG="/var/log/cloudflared.log"
CF_BIN="/usr/local/bin/cloudflared"

# --------------------------------------------------------------
# 颜色定义（非终端环境下自动禁用，例如输出被重定向到文件时）
# --------------------------------------------------------------
if [ -t 1 ]; then
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_BRIGHT_GREEN='\033[1;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
    C_NC='\033[0m'
else
    C_RED=""; C_GREEN=""; C_BRIGHT_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_NC=""
fi

cecho() {
    # 用法: cecho <颜色变量> <文字>
    color="$1"; shift
    printf "%b%s%b\n" "$color" "$*" "$C_NC"
}

# log()/err() 输出到 stderr，避免污染被 $(...) 捕获的函数返回值
log()  { printf "%b[Komari]%b %s\n" "$C_BLUE" "$C_NC" "$1" >&2; }
warn() { printf "%b[Komari] ⚠️  %s%b\n" "$C_YELLOW" "$1" "$C_NC" >&2; }
ok()   { printf "%b[Komari] ✅ %s%b\n" "$C_BRIGHT_GREEN" "$1" "$C_NC" >&2; }
err()  { printf "%b[Komari] ❌ %s%b\n" "$C_RED" "$1" "$C_NC" >&2; exit 1; }

# --------------------------------------------------------------
# 权限检查
# --------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 权限运行此脚本 (例如: sudo sh $0)"
fi

# --------------------------------------------------------------
# 公共函数
# --------------------------------------------------------------

detect_init() {
    if pidof systemd >/dev/null 2>&1 || [ -d /run/systemd/system ]; then
        echo "systemd"
    elif [ -f /sbin/openrc-run ]; then
        echo "openrc"
    else
        echo "unknown"
    fi
}

detect_arch() {
    raw=$(uname -m)
    case "$raw" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "arm" ;;
        *) err "不支持的架构: ${raw}" ;;
    esac
}

# 带超时的执行，避免目标程序不支持某参数时卡死脚本
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 "$@"
    else
        "$@"
    fi
}

# 下载到临时文件并校验，成功后返回临时文件路径（不直接覆盖目标）
download_and_verify() {
    url="$1"; name="$2"
    tmp=$(mktemp)
    log "下载 ${name} 到临时文件..."
    if ! wget -qO "$tmp" "$url"; then
        rm -f "$tmp"
        err "${name} 下载失败，请检查网络。"
    fi
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        err "${name} 下载后文件为空，链接可能失效。"
    fi
    chmod +x "$tmp"
    echo "$tmp"
}

svc_stop() {
    init=$(detect_init)
    case "$init" in
        systemd) systemctl stop "$1" 2>/dev/null || log "服务 $1 未运行或停止失败，继续。" ;;
        openrc)  service "$1" stop 2>/dev/null || log "服务 $1 未运行或停止失败，继续。" ;;
    esac
}

svc_start() {
    init=$(detect_init)
    case "$init" in
        systemd) systemctl start "$1" || err "服务 $1 启动失败，请查看 systemctl status $1" ;;
        openrc)  service "$1" start   || err "服务 $1 启动失败，请查看 /var/log/$1.log" ;;
        *) err "未识别的初始化系统，无法启动 $1" ;;
    esac
}

svc_restart() {
    init=$(detect_init)
    case "$init" in
        systemd) systemctl restart "$1" || err "服务 $1 重启失败" ;;
        openrc)  service "$1" restart   || err "服务 $1 重启失败" ;;
        *) err "未识别的初始化系统，无法重启 $1" ;;
    esac
}

# --------------------------------------------------------------
# 生成服务配置文件（部署和换 Token 都复用这两个函数，避免用 sed 改配置文件的脆弱性）
# --------------------------------------------------------------
write_systemd_units() {
    cat > /etc/systemd/system/komari.service <<EOF
[Unit]
Description=Komari Monitor
After=network.target
[Service]
Type=simple
ExecStart=/bin/sh -c '${KOMARI_BIN} server >> ${KOMARI_LOG} 2>&1'
WorkingDirectory=${KOMARI_DIR}
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
Type=simple
ExecStart=${CF_BIN} tunnel run --token ${CF_TOKEN}
Restart=always
RestartSec=5
StandardOutput=append:${CLOUDFLARED_LOG}
StandardError=append:${CLOUDFLARED_LOG}
[Install]
WantedBy=multi-user.target
EOF
    # cloudflared.service 里明文含有 Token，收紧权限，避免本地其他用户读取
    chmod 600 /etc/systemd/system/cloudflared.service
}

write_openrc_units() {
    cat > /etc/init.d/komari <<EOF
#!/sbin/openrc-run
name="komari"
command="${KOMARI_BIN}"
command_args="server"
command_user="root"
directory="${KOMARI_DIR}"
pidfile="/run/komari.pid"
command_background="yes"
output_log="${KOMARI_LOG}"
error_log="${KOMARI_LOG}"
respawn_delay=5
depend() { need net; }
EOF
    cat > /etc/init.d/cloudflared <<EOF
#!/sbin/openrc-run
name="cloudflared"
command="${CF_BIN}"
command_args="tunnel run --token ${CF_TOKEN}"
command_user="root"
pidfile="/run/cloudflared.pid"
command_background="yes"
output_log="${CLOUDFLARED_LOG}"
error_log="${CLOUDFLARED_LOG}"
respawn_delay=5
depend() { need net; use dns; }
EOF
    chmod 700 /etc/init.d/komari /etc/init.d/cloudflared
}

# --------------------------------------------------------------
# 功能 1：部署安装
# --------------------------------------------------------------
do_install() {
    if [ -z "$CF_TOKEN" ]; then
        printf "%b请输入 Cloudflare Tunnel Token: %b" "$C_CYAN" "$C_NC"
        read -r CF_TOKEN
    fi
    [ -z "$CF_TOKEN" ] && err "Token 不能为空。"

    RESET_DATA="n"
    if [ -d "${KOMARI_DIR}/data" ]; then
        printf "%b检测到已存在的数据目录，是否清空并重置密码？[y/N]: %b" "$C_YELLOW" "$C_NC"
        read -r RESET_DATA
    fi

    log "检查基础依赖 (curl/wget)..."
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl wget
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y curl wget
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget
    fi
    command -v wget >/dev/null 2>&1 || err "wget 不可用。"

    ARCH=$(detect_arch)
    log "识别架构: ${ARCH}"

    mkdir -p "$KOMARI_DIR"
    pkill -f "$KOMARI_BIN" 2>/dev/null || true

    if [ "$RESET_DATA" = "y" ] || [ "$RESET_DATA" = "Y" ]; then
        log "清空旧数据目录..."
        rm -rf "${KOMARI_DIR}/data"
    fi

    tmp_komari=$(download_and_verify "https://github.com/komari-monitor/komari/releases/latest/download/komari-linux-${ARCH}" "komari")
    mv "$tmp_komari" "$KOMARI_BIN"
    chmod +x "$KOMARI_BIN"

    tmp_cf=$(download_and_verify "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" "cloudflared")
    mv "$tmp_cf" "$CF_BIN"
    chmod +x "$CF_BIN"

    init=$(detect_init)
    if [ "$init" = "systemd" ]; then
        write_systemd_units
        systemctl daemon-reload
        systemctl enable --now komari cloudflared
    elif [ "$init" = "openrc" ]; then
        write_openrc_units
        rc-update add komari default
        rc-update add cloudflared default
        service komari restart
        service cloudflared restart
    else
        err "未识别的初始化系统，二进制已就绪于 ${KOMARI_BIN} 和 ${CF_BIN}，请手动配置启动方式。"
    fi

    sleep 2
    cecho "$C_BRIGHT_GREEN" "================================================"
    cecho "$C_BRIGHT_GREEN" "✅ 部署完成"
    cecho "$C_CYAN" "🔍 查看初始密码: grep -E 'Password|User' ${KOMARI_LOG}"
    cecho "$C_BRIGHT_GREEN" "================================================"
}

# --------------------------------------------------------------
# 功能 2：升级 Komari
# --------------------------------------------------------------
do_upgrade() {
    [ -x "$KOMARI_BIN" ] || err "未检测到已安装的 komari (${KOMARI_BIN} 不存在)，请先执行安装。"

    ARCH=$(detect_arch)
    log "识别架构: ${ARCH}"

    # 备份数据
    if [ -d "${KOMARI_DIR}/data" ]; then
        backup_dir="${KOMARI_DIR}/data_backup_$(date +%Y%m%d_%H%M%S)"
        cp -r "${KOMARI_DIR}/data" "$backup_dir"
        log "数据已备份至 ${backup_dir}"
    fi

    # 备份旧二进制（用于回滚，会覆盖上一次的 .bak）
    cp "$KOMARI_BIN" "${KOMARI_BIN}.bak"
    log "旧版本二进制已备份为 ${KOMARI_BIN}.bak"

    # 下载并验证新版本，验证通过才替换
    tmp_new=$(download_and_verify "https://github.com/komari-monitor/komari/releases/latest/download/komari-linux-${ARCH}" "komari 新版本")

    if ! run_with_timeout "$tmp_new" --version >/dev/null 2>&1; then
        rm -f "$tmp_new"
        err "新版本二进制无法正常执行，已中止升级，旧版本未受影响。"
    fi

    svc_stop komari
    mv "$tmp_new" "$KOMARI_BIN"
    chmod +x "$KOMARI_BIN"

    if svc_start komari; then
        sleep 2
        cecho "$C_BRIGHT_GREEN" "================================================"
        cecho "$C_BRIGHT_GREEN" "✅ 升级完成！请刷新网页查看版本号。"
        cecho "$C_CYAN" "   如需回滚: mv ${KOMARI_BIN}.bak ${KOMARI_BIN} && 重启服务"
        cecho "$C_BRIGHT_GREEN" "================================================"
    else
        warn "新版本启动失败，正在自动回滚..."
        mv "${KOMARI_BIN}.bak" "$KOMARI_BIN"
        svc_start komari
        err "升级失败，已自动回滚至旧版本。"
    fi
}

# --------------------------------------------------------------
# 功能 3：更换 Token（复用 write_*_units，避免用 sed 正则改配置的脆弱性）
# --------------------------------------------------------------
do_change_token() {
    printf "%b请输入新的 Cloudflare Tunnel Token: %b" "$C_CYAN" "$C_NC"
    read -r NEW_TOKEN
    [ -z "$NEW_TOKEN" ] && err "Token 不能为空。"

    init=$(detect_init)
    case "$init" in
        systemd)
            [ -f /etc/systemd/system/cloudflared.service ] || err "未找到 cloudflared.service，请先执行安装。"
            CF_TOKEN="$NEW_TOKEN"
            write_systemd_units
            systemctl daemon-reload
            svc_restart cloudflared
            ;;
        openrc)
            [ -f /etc/init.d/cloudflared ] || err "未找到 /etc/init.d/cloudflared，请先执行安装。"
            CF_TOKEN="$NEW_TOKEN"
            write_openrc_units
            svc_restart cloudflared
            ;;
        *)
            err "未识别的初始化系统，无法自动更新 Token。"
            ;;
    esac

    cecho "$C_BRIGHT_GREEN" "================================================"
    cecho "$C_BRIGHT_GREEN" "✅ Token 已更新并重启 cloudflared 服务。"
    cecho "$C_BRIGHT_GREEN" "================================================"
}

# --------------------------------------------------------------
# 功能 4：卸载
# --------------------------------------------------------------
do_uninstall() {
    cecho "$C_RED$C_BOLD" "⚠️  此操作将停止并删除 Komari 及相关服务、数据。"
    printf "%b确定要继续吗？[y/N]: %b" "$C_YELLOW" "$C_NC"
    read -r confirm
    case "$confirm" in
        y|Y) : ;;
        *) log "已取消。"; return 0 ;;
    esac

    printf "%b是否同时删除 cloudflared 二进制？如果本机还有其他 Tunnel 在用它，请选 N。[y/N]: %b" "$C_YELLOW" "$C_NC"
    read -r remove_cf

    had_backups="n"
    if ls -d "${KOMARI_DIR}"/data_backup_* >/dev/null 2>&1; then
        had_backups="y"
        printf "%b检测到历史备份目录 (data_backup_*)，是否一并删除？[y/N]: %b" "$C_YELLOW" "$C_NC"
        read -r remove_backups
    else
        remove_backups="n"
    fi

    init=$(detect_init)
    case "$init" in
        systemd)
            log "检测到 systemd，正在停止并移除服务..."
            systemctl stop komari cloudflared 2>/dev/null || true
            systemctl disable komari cloudflared 2>/dev/null || true
            rm -f /etc/systemd/system/komari.service /etc/systemd/system/cloudflared.service
            systemctl daemon-reload || true
            ;;
        openrc)
            log "检测到 OpenRC，正在停止并移除服务..."
            service komari stop 2>/dev/null || true
            service cloudflared stop 2>/dev/null || true
            rc-update del komari default 2>/dev/null || true
            rc-update del cloudflared default 2>/dev/null || true
            rm -f /etc/init.d/komari /etc/init.d/cloudflared
            ;;
        *)
            warn "未识别的初始化系统，跳过服务清理，请手动检查是否有残留的 komari/cloudflared 进程。"
            ;;
    esac

    # 兜底：清理可能残留的手动运行进程（不受服务管理器控制的情况）
    pkill -f "$KOMARI_BIN" 2>/dev/null || true

    log "正在清理文件..."
    if [ "$remove_backups" = "y" ] || [ "$remove_backups" = "Y" ]; then
        rm -rf "$KOMARI_DIR"
    else
        # 明确删除主程序本身及其备份、data 目录，不用名称排除法（避免目录与二进制同名 "komari" 导致误伤保留）
        rm -f "${KOMARI_BIN}" "${KOMARI_BIN}.bak"
        rm -rf "${KOMARI_DIR}/data"
    fi

    if [ "$remove_cf" = "y" ] || [ "$remove_cf" = "Y" ]; then
        rm -f "$CF_BIN"
    else
        log "已保留 ${CF_BIN}"
    fi

    rm -f /run/komari.pid /run/cloudflared.pid

    cecho "$C_BRIGHT_GREEN" "------------------------------------------------"
    cecho "$C_BRIGHT_GREEN" "✅ 卸载完成。"
    if [ "$had_backups" = "y" ] && [ "$remove_backups" != "y" ] && [ "$remove_backups" != "Y" ]; then
        cecho "$C_CYAN" "   备份目录已保留在 ${KOMARI_DIR}"
    fi
    cecho "$C_BRIGHT_GREEN" "------------------------------------------------"
}

# --------------------------------------------------------------
# 版本信息
# --------------------------------------------------------------
get_current_version() {
    if [ -x "$KOMARI_BIN" ]; then
        ver=$(run_with_timeout "$KOMARI_BIN" --version 2>/dev/null | head -n1) || ver=""
        if [ -n "$ver" ]; then echo "$ver"; else echo "未知（无法获取）"; fi
    else
        echo "未安装"
    fi
}

get_latest_version() {
    api_url="https://api.github.com/repos/komari-monitor/komari/releases/latest"
    resp=""
    if command -v curl >/dev/null 2>&1; then
        resp=$(curl -s --max-time 5 "$api_url" 2>/dev/null) || resp=""
    elif command -v wget >/dev/null 2>&1; then
        resp=$(wget -qO- --timeout=5 "$api_url" 2>/dev/null) || resp=""
    fi
    latest=$(echo "$resp" | grep '"tag_name"' | head -n1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    if [ -n "$latest" ]; then echo "$latest"; else echo "未知（无法获取，请检查网络）"; fi
}

# --------------------------------------------------------------
# 主菜单
# --------------------------------------------------------------
CURRENT_VER=$(get_current_version)
LATEST_VER=$(get_latest_version)

VER_COLOR="$C_CYAN"
VER_NOTE=""
if [ "$CURRENT_VER" = "未安装" ]; then
    VER_COLOR="$C_YELLOW"
elif [ "$CURRENT_VER" != "未知（无法获取）" ] && [ "$LATEST_VER" != "未知（无法获取，请检查网络）" ]; then
    case "$CURRENT_VER" in
        *"$LATEST_VER"*) VER_NOTE=" (已是最新)"; VER_COLOR="$C_BRIGHT_GREEN" ;;
        *) VER_NOTE=" (有更新可用)"; VER_COLOR="$C_YELLOW" ;;
    esac
fi

cecho "$C_BOLD$C_CYAN" "================================================"
cecho "$C_BOLD$C_CYAN" " Komari 管理脚本"
cecho "$C_CYAN"        "------------------------------------------------"
printf " 当前版本: %b%s%b\n" "$VER_COLOR" "$CURRENT_VER" "$C_NC"
printf " 最新版本: %b%s%s%b\n" "$VER_COLOR" "$LATEST_VER" "$VER_NOTE" "$C_NC"
cecho "$C_CYAN"        "------------------------------------------------"
printf "  %b1) 部署安装%b\n"            "$C_BRIGHT_GREEN" "$C_NC"
printf "  %b2) 升级 Komari%b\n"          "$C_BRIGHT_GREEN" "$C_NC"
printf "  %b3) 更换 Cloudflare Token%b\n" "$C_BRIGHT_GREEN" "$C_NC"
printf "  %b4) 卸载%b\n"                 "$C_BRIGHT_GREEN" "$C_NC"
printf "  %b0) 退出%b\n"                 "$C_BRIGHT_GREEN" "$C_NC"
cecho "$C_BOLD$C_CYAN" "================================================"
printf "%b请选择操作 [0-4]: %b" "$C_CYAN" "$C_NC"
read -r choice

case "$choice" in
    1) do_install ;;
    2) do_upgrade ;;
    3) do_change_token ;;
    4) do_uninstall ;;
    0) log "已退出。" ;;
    *) err "无效选择。" ;;
esac
