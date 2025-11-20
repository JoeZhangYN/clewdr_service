#!/bin/bash
# ClewdR & SillyTavern 完整管理工具
# 使用: curl -O -C - https://raw.githubusercontent.com/JoeZhangYN/clewdr_service/main/clewdr_service.sh && chmod +x clewdr_service.sh && ./clewdr_service.sh

# ========== 配置 ==========
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLEWDR_DIR="$SCRIPT_DIR/clewdr"
ST_DIR="$SCRIPT_DIR/SillyTavern"
CONFIG="$CLEWDR_DIR/clewdr.toml"

# ========== 日志 ==========
log() { echo "[$1] $2"; }
info() { log "INFO" "$@"; }
success() { log "OK" "$@"; }
error() { log "ERROR" "$@"; read -n1 -p "按任意键继续..."; return 1; }

# ========== 检查Root权限 ==========
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请以root用户运行此脚本"
        return 1
    fi
    return 0
}

# ========== 依赖检查 ==========
check_deps() {
    info "检查系统依赖..."
    local deps=(curl git npm node unzip)
    local missing=()
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [[ ${#missing[@]} -ne 0 ]]; then
        error "缺少依赖: ${missing[*]}"
        return 1
    fi
    success "依赖检查通过"
    return 0
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

# ========== 获取本地版本 ==========
get_local_version() {
    if [[ -f "$CLEWDR_DIR/version.txt" ]]; then
        cat "$CLEWDR_DIR/version.txt"
    else
        echo "未安装"
    fi
}

# ========== 安装 ClewdR ==========
install_clewdr() {
    info "开始安装 ClewdR..."
    
    local version=$(get_latest_version "Xerxes-2/clewdr")
    if [[ -z "$version" ]]; then
        error "无法获取版本信息"
        return 1
    fi
    
    local local_version=$(get_local_version)
    info "本地版本: $local_version"
    info "最新版本: $version"
    
    if [[ "$local_version" == "$version" ]]; then
        read -p "已是最新版本，是否重新安装？(y/N): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && { info "取消安装"; return 0; }
    fi
    
    # 检查服务状态并停止
    if systemctl is-active --quiet clewdr.service 2>/dev/null; then
        info "检测到服务运行中，正在停止..."
        systemctl stop clewdr.service
        sleep 2
    fi
    
    local arch=$(detect_arch) || return 1
    info "目标平台: $arch"
    
    # 备份配置文件
    if [[ -f "$CONFIG" ]]; then
        info "备份配置文件..."
        cp "$CONFIG" "$CONFIG.bak"
    fi
    
    mkdir -p "$CLEWDR_DIR"
    cd "$CLEWDR_DIR" || return 1
    
    local url="https://github.com/Xerxes-2/clewdr/releases/download/${version}/clewdr-${arch}.zip"
    info "下载: clewdr-${arch}.zip"
    
    if ! curl -fL "$url" -o clewdr.zip 2>/dev/null; then
        error "下载失败"
        return 1
    fi
    
    if ! unzip -qt clewdr.zip &>/dev/null; then
        rm -f clewdr.zip
        error "文件损坏"
        return 1
    fi
    
    info "解压安装包..."
    unzip -oq clewdr.zip
    rm clewdr.zip
    chmod +x clewdr
    
    # 保存版本信息
    echo "$version" > version.txt
    
    # 恢复配置文件
    if [[ -f "$CONFIG.bak" ]]; then
        info "恢复配置文件..."
        cp "$CONFIG.bak" "$CONFIG"
    fi
    
    success "ClewdR 安装完成 (版本: $version)"
    
    # 询问是否重启服务
    if systemctl list-unit-files | grep -q "clewdr.service"; then
        read -p "是否重启服务？(y/N): " restart
        if [[ "$restart" =~ ^[Yy]$ ]]; then
            systemctl start clewdr.service
            sleep 2
            systemctl status clewdr.service --no-pager
        fi
    fi
    
    return 0
}

# ========== 安装 SillyTavern ==========
install_st() {
    info "开始安装 SillyTavern..."
    
    if [[ -d "$ST_DIR/.git" ]]; then
        info "更新现有安装..."
        cd "$ST_DIR" && git pull
        if [ $? -ne 0 ]; then
            error "更新失败"
            return 1
        fi
    else
        info "克隆仓库..."
        if ! git clone --depth 1 --branch release \
            "https://github.com/SillyTavern/SillyTavern" "$ST_DIR"; then
            error "克隆失败"
            return 1
        fi
    fi
    
    info "安装依赖..."
    cd "$ST_DIR"
    if ! npm install --omit=dev --loglevel=error; then
        error "依赖安装失败"
        return 1
    fi
    
    success "SillyTavern 安装完成"
    return 0
}

# ========== 配置管理 ==========
config_set() {
    if [[ ! -f "$CONFIG" ]]; then
        error "配置文件不存在，请先运行 ClewdR 生成配置"
        return 1
    fi
    
    case "$1" in
        public)
            sed -i 's/127\.0\.0\.1/0.0.0.0/' "$CONFIG"
            success "已开放公网访问 (0.0.0.0)"
            ;;
        port)
            read -p "输入端口号 [1-65535]: " port
            if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
                error "无效端口"
                return 1
            fi
            sed -i -E "s/^(#?\s*port\s*=).*/port = $port/" "$CONFIG"
            success "端口设置为: $port"
            ;;
    esac
    return 0
}

# ========== 直接启动 ==========
start_direct() {
    local name=$1 dir=$2 cmd=$3
    if [[ ! -d "$dir" ]]; then
        error "$name 未安装"
        return 1
    fi
    info "启动 $name..."
    cd "$dir" && eval "$cmd"
}

# ========== 创建服务 ==========
create_service() {
    check_root || return 1
    
    if [[ ! -x "$CLEWDR_DIR/clewdr" ]]; then
        error "ClewdR 未安装，请先安装"
        return 1
    fi
    
    info "创建 systemd 服务文件..."
    
    cat > /etc/systemd/system/clewdr.service <<EOF
[Unit]
Description=ClewdR Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$CLEWDR_DIR
ExecStart=$CLEWDR_DIR/clewdr
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    chmod 644 /etc/systemd/system/clewdr.service
    systemctl daemon-reload
    success "服务文件已创建"
    
    echo ""
    echo "服务管理命令:"
    echo "  启动服务: systemctl start clewdr"
    echo "  停止服务: systemctl stop clewdr"
    echo "  开机启动: systemctl enable clewdr"
    echo "  查看状态: systemctl status clewdr"
    return 0
}

# ========== 启动服务 ==========
start_service() {
    check_root || return 1
    
    info "正在启动服务..."
    systemctl start clewdr.service
    
    sleep 2
    
    if systemctl is-active --quiet clewdr.service; then
        success "服务已启动"
        echo ""
        systemctl status clewdr.service --no-pager -l
    else
        error "服务启动失败"
        echo ""
        echo "查看详细日志: journalctl -u clewdr.service -n 50"
        return 1
    fi
    return 0
}

# ========== 停止服务 ==========
stop_service() {
    check_root || return 1
    
    info "正在停止服务..."
    systemctl stop clewdr.service
    
    sleep 1
    
    if systemctl is-active --quiet clewdr.service; then
        error "服务停止失败"
        return 1
    else
        success "服务已停止"
    fi
    return 0
}

# ========== 重启服务 ==========
restart_service() {
    check_root || return 1
    
    info "正在重启服务..."
    systemctl restart clewdr.service
    
    sleep 2
    
    if systemctl is-active --quiet clewdr.service; then
        success "服务已重启"
        echo ""
        systemctl status clewdr.service --no-pager -l
    else
        error "服务重启失败"
        echo ""
        echo "查看详细日志: journalctl -u clewdr.service -n 50"
        return 1
    fi
    return 0
}

# ========== 查看服务状态 ==========
status_service() {
    echo "=========================================="
    echo "服务状态:"
    echo "=========================================="
    systemctl status clewdr.service --no-pager -l
    echo ""
    echo "=========================================="
    echo "最近日志:"
    echo "=========================================="
    journalctl -u clewdr.service -n 20 --no-pager
    return 0
}

# ========== 启用开机自启 ==========
enable_service() {
    check_root || return 1
    
    systemctl enable clewdr.service
    if [ $? -eq 0 ]; then
        success "服务已设置为开机自启"
    else
        error "设置失败"
        return 1
    fi
    return 0
}

# ========== 禁用开机自启 ==========
disable_service() {
    check_root || return 1
    
    systemctl disable clewdr.service
    if [ $? -eq 0 ]; then
        success "服务已禁用开机自启"
    else
        error "禁用失败"
        return 1
    fi
    return 0
}

# ========== 卸载服务 ==========
remove_service() {
    check_root || return 1
    
    info "正在卸载服务..."
    systemctl stop clewdr.service 2>/dev/null
    systemctl disable clewdr.service 2>/dev/null
    rm -f /etc/systemd/system/clewdr.service
    systemctl daemon-reload
    success "服务已卸载"
    return 0
}

# ========== 显示菜单 ==========
show_menu() {
    clear
    echo "==========================================="
    echo "     ClewdR & SillyTavern 管理工具     "
    echo "==========================================="
    
    # 显示状态
    local cr_st="未安装"
    local st_st="未安装"
    local service_st="未安装"
    
    if [[ -x "$CLEWDR_DIR/clewdr" ]]; then
        local version=$(get_local_version)
        cr_st="已安装 ($version)"
    fi
    
    if [[ -d "$ST_DIR" ]]; then
        st_st="已安装"
    fi
    
    if systemctl list-unit-files | grep -q "clewdr.service"; then
        if systemctl is-active --quiet clewdr.service; then
            service_st="运行中"
        else
            service_st="已停止"
        fi
    fi
    
    echo "ClewdR: $cr_st"
    echo "SillyTavern: $st_st"
    echo "服务状态: $service_st"
    echo ""
    
    echo "[安装管理]"
    echo "1) 安装/更新 ClewdR"
    echo "2) 安装/更新 SillyTavern"
    echo ""
    echo "[直接启动]"
    echo "3) 启动 ClewdR (前台运行)"
    echo "4) 启动 SillyTavern (前台运行)"
    echo ""
    echo "[服务管理]"
    echo "5) 安装服务"
    echo "6) 启动服务"
    echo "7) 停止服务"
    echo "8) 重启服务"
    echo "9) 查看服务状态"
    echo "10) 启用开机自启"
    echo "11) 禁用开机自启"
    echo "12) 卸载服务"
    echo ""
    echo "[配置管理]"
    echo "13) 开放公网访问"
    echo "14) 设置端口号"
    echo ""
    echo "0) 退出"
    echo "==========================================="
}

# ========== 主循环 ==========
main_menu() {
    show_menu
    
    read -rp "请选择操作 [0-14]: " choice
    echo
    
    case $choice in
        1)
            check_deps && install_clewdr
            ;;
        2)
            check_deps && install_st
            ;;
        3)
            start_direct "ClewdR" "$CLEWDR_DIR" "./clewdr"
            ;;
        4)
            start_direct "SillyTavern" "$ST_DIR" "node server.js"
            ;;
        5)
            create_service
            ;;
        6)
            start_service
            ;;
        7)
            stop_service
            ;;
        8)
            restart_service
            ;;
        9)
            status_service
            ;;
        10)
            enable_service
            ;;
        11)
            disable_service
            ;;
        12)
            remove_service
            ;;
        13)
            config_set public
            ;;
        14)
            config_set port
            ;;
        0)
            echo "退出脚本。"
            return 1
            ;;
        *)
            error "无效选项，请重新选择。"
            ;;
    esac
    
    echo
    read -n1 -rp "按任意键继续..." key
    return 0
}

# ========== 主函数 ==========
main() {
    # 检查root权限
    check_root || exit 1
    
    # 主循环
    while true; do
        main_menu
        [ $? -ne 0 ] && break
    done
    
    echo "服务管理脚本执行完毕。"
    exit 0
}

# ========== 脚本入口 ==========
main "$@"