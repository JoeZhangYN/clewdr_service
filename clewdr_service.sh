#!/bin/bash
# ClewdR & SillyTavern 完整管理工具
# 使用: chmod +x clewdr_manager.sh && bash ./clewdr_manager.sh

# ========== 配置 ==========
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLEWDR_DIR="$SCRIPT_DIR/clewdr"
ST_DIR="$SCRIPT_DIR/SillyTavern"
CONFIG="$CLEWDR_DIR/clewdr.toml"

# ========== 颜色 ==========
C_RED='\e[31m'
C_GREEN='\e[32m'
C_YELLOW='\e[33m'
C_BLUE='\e[34m'
C_CYAN='\e[36m'
C_WHITE='\e[97m'
C_NC='\e[0m'

# ========== 日志 ==========
log() { echo -e "${2:-$C_BLUE}[$1]$C_NC ${@:3}" >&2; }
info() { log INFO "$C_BLUE" "$@"; }
success() { log OK "$C_GREEN" "$@"; }
warn() { log WARN "$C_YELLOW" "$@"; }
error() { log ERROR "$C_RED" "$@"; read -n1 -p "按任意键继续..."; return 1; }

# ========== 依赖检查 ==========
check_deps() {
    local deps=(curl git npm node unzip)
    local missing=()
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    [[ ${#missing[@]} -eq 0 ]] || { error "缺少依赖: ${missing[*]}"; return 1; }
    success "依赖检查通过"
}

# ========== 架构检测 ==========
detect_arch() {
    [[ "${PREFIX:-}" == *termux* ]] && echo "android-aarch64" && return
    case "$(uname -m)" in
        x86_64|amd64) echo "musllinux-x86_64" ;;
        aarch64|arm64) echo "musllinux-aarch64" ;;
        *) error "不支持的架构: $(uname -m)"; return 1 ;;
    esac
}

# ========== 获取最新版本 ==========
get_latest_version() {
    curl -s "https://api.github.com/repos/$1/releases/latest" | grep '"tag_name"' | cut -d'"' -f4
}

# ========== 安装 ClewdR ==========
install_clewdr() {
    info "开始安装 ClewdR..."
    
    local version=$(get_latest_version "Xerxes-2/clewdr")
    [[ -z "$version" ]] && { error "无法获取版本信息"; return 1; }
    
    local arch=$(detect_arch) || return 1
    info "版本: $version | 平台: $arch"
    
    mkdir -p "$CLEWDR_DIR" && cd "$CLEWDR_DIR" || return 1
    
    local url="https://github.com/Xerxes-2/clewdr/releases/download/${version}/clewdr-${arch}.zip"
    info "下载中..."
    
    curl -fL "$url" -o clewdr.zip 2>/dev/null || { error "下载失败"; return 1; }
    unzip -qt clewdr.zip &>/dev/null || { rm -f clewdr.zip; error "文件损坏"; return 1; }
    
    info "解压中..."
    unzip -oq clewdr.zip && rm clewdr.zip || { error "解压失败"; return 1; }
    chmod +x clewdr
    
    success "ClewdR 安装完成"
}

# ========== 安装 SillyTavern ==========
install_st() {
    info "开始安装 SillyTavern..."
    
    if [[ -d "$ST_DIR/.git" ]]; then
        info "更新现有安装..."
        (cd "$ST_DIR" && git pull) || { error "更新失败"; return 1; }
    else
        info "克隆仓库..."
        git clone --depth 1 --branch release \
            "https://github.com/SillyTavern/SillyTavern" "$ST_DIR" || { error "克隆失败"; return 1; }
    fi

    info "安装依赖..."
    (cd "$ST_DIR" && npm install --omit=dev --loglevel=error) || { error "依赖安装失败"; return 1; }
    
    success "SillyTavern 安装完成"
}

# ========== 配置管理 ==========
config_set() {
    [[ ! -f "$CONFIG" ]] && { error "配置文件不存在，请先运行 ClewdR"; return 1; }
    
    case "$1" in
        public)
            sed -i 's/127\.0\.0\.1/0.0.0.0/' "$CONFIG"
            success "已开放公网访问 (0.0.0.0)"
            ;;
        port)
            read -p "输入端口号 [1-65535]: " port
            [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || { error "无效端口"; return 1; }
            sed -i -E "s/^(#?\s*port\s*=).*/port = $port/" "$CONFIG"
            success "端口设置为: $port"
            ;;
    esac
}

# ========== 直接启动 ==========
start_direct() {
    local name=$1 dir=$2 cmd=$3
    [[ ! -d "$dir" ]] && { error "$name 未安装"; return 1; }
    info "启动 $name..."
    echo -e "\e]0;$name\a"
    cd "$dir" && eval "$cmd"
}

# ========== Systemd 服务 ==========
check_root() {
    [[ "$EUID" -ne 0 ]] && { error "需要 root 权限"; return 1; }
}

create_service() {
    check_root || return 1
    [[ ! -x "$CLEWDR_DIR/clewdr" ]] && { error "ClewdR 未安装"; return 1; }
    
    cat > /etc/systemd/system/clewdr.service <<EOF
[Unit]
Description=ClewdR Service
After=network.target

[Service]
Type=simple
User=${SUDO_USER:-root}
WorkingDirectory=$CLEWDR_DIR
ExecStart=$CLEWDR_DIR/clewdr
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    chmod 644 /etc/systemd/system/clewdr.service
    systemctl daemon-reload
    success "服务已创建"
}

service_ctl() {
    check_root || return 1
    local action=$1
    case "$action" in
        start|stop|restart|status) 
            systemctl "$action" clewdr.service
            [[ "$action" != "status" ]] && success "服务已${action}"
            ;;
        enable|disable)
            systemctl "$action" clewdr.service
            success "已${action}开机自启"
            ;;
        remove)
            systemctl stop clewdr.service 2>/dev/null
            systemctl disable clewdr.service 2>/dev/null
            rm -f /etc/systemd/system/clewdr.service
            systemctl daemon-reload
            success "服务已卸载"
            ;;
    esac
}

# ========== 菜单 ==========
show_menu() {
    clear
    echo -e "${C_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_NC}"
    echo -e "${C_WHITE}    ClewdR & SillyTavern 管理工具    ${C_NC}"
    echo -e "${C_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_NC}"
    
    # 状态显示
    local cr_st="❌" st_st="❌"
    [[ -x "$CLEWDR_DIR/clewdr" ]] && cr_st="${C_GREEN}✓${C_NC}"
    [[ -d "$ST_DIR" ]] && st_st="${C_GREEN}✓${C_NC}"
    echo -e "状态: ClewdR [$cr_st] | SillyTavern [$st_st]"
    echo
    
    cat <<EOF
${C_BLUE}[安装]${C_NC}
 1. 安装/更新 ClewdR        2. 安装/更新 SillyTavern

${C_BLUE}[直接启动]${C_NC}
 3. 启动 ClewdR (前台)      4. 启动 SillyTavern (前台)

${C_BLUE}[服务管理]${C_NC}
 5. 创建服务    6. 启动      7. 停止      8. 重启
 9. 查看状态   10. 开机自启  11. 禁用自启  12. 卸载服务

${C_BLUE}[配置]${C_NC}
13. 开放公网访问          14. 设置端口号

${C_RED} 0. 退出${C_NC}
EOF
    echo -e "${C_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_NC}"
    echo
}

# ========== 主循环 ==========
main() {
    while true; do
        show_menu
        read -rp "选择 [0-14]: " choice
        echo
        
        case "$choice" in
            1) check_deps && install_clewdr ;;
            2) check_deps && install_st ;;
            3) start_direct "ClewdR" "$CLEWDR_DIR" "./clewdr" ;;
            4) start_direct "SillyTavern" "$ST_DIR" "node server.js" ;;
            5) create_service ;;
            6) service_ctl start ;;
            7) service_ctl stop ;;
            8) service_ctl restart ;;
            9) service_ctl status ;;
            10) service_ctl enable ;;
            11) service_ctl disable ;;
            12) service_ctl remove ;;
            13) config_set public ;;
            14) config_set port ;;
            0) success "再见！"; exit 0 ;;
            *) error "无效选项: $choice" ;;
        esac
        
        echo
        read -n1 -rp "按任意键继续..." key
    done
}

main "$@"